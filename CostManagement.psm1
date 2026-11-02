#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-CostConfiguration {
    param([Parameter(Mandatory)][string]$Path)

    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($config.schemaVersion -ne 1 -or @($config.tenants).Count -eq 0) {
        throw 'Expected schemaVersion 1 and at least one tenant in the configuration.'
    }
    $seen = @{}
    foreach ($tenant in $config.tenants) {
        foreach ($field in 'tenantId', 'clientId', 'applicationObjectId') {
            $parsed = [guid]::Empty
            if (-not [guid]::TryParse($tenant.$field, [ref]$parsed) -or $parsed -eq [guid]::Empty) {
                throw "Invalid $field in tenant configuration."
            }
        }
        if ([string]::IsNullOrWhiteSpace($tenant.tenantName) -or
            $tenant.certificateThumbprint -notmatch '^[A-Fa-f0-9]{40}$') {
            throw "Invalid tenant name or certificate thumbprint for $($tenant.tenantId)."
        }
        if ($seen.ContainsKey($tenant.tenantId)) {
            throw "Duplicate tenant ID: $($tenant.tenantId)."
        }
        $seen[$tenant.tenantId] = $true
    }
    return $config
}

function Get-CostCertificate {
    param([Parameter(Mandatory)][string]$Thumbprint)

    if (-not $IsWindows) {
        throw 'Certificate-store authentication requires Windows.'
    }
    $certificate = Get-Item -LiteralPath "Cert:\CurrentUser\My\$Thumbprint"
    if (-not $certificate.HasPrivateKey -or $certificate.NotAfter.ToUniversalTime() -le [datetime]::UtcNow -or
        $certificate.NotBefore.ToUniversalTime() -gt [datetime]::UtcNow) {
        throw "Certificate $Thumbprint must have an accessible private key and be currently valid."
    }
    return $certificate
}

function ConvertTo-Base64Url {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-CostClientAssertion {
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate
    )

    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $header = @{
        alg = 'PS256'
        typ = 'JWT'
        'x5t#S256' = ConvertTo-Base64Url ($Certificate.GetCertHash([Security.Cryptography.HashAlgorithmName]::SHA256))
    }
    $claims = @{
        aud = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
        iss = $ClientId
        sub = $ClientId
        jti = [guid]::NewGuid().ToString()
        iat = $now
        nbf = $now - 60
        exp = $now + 300
    }
    $parts = @($header, $claims) | ForEach-Object {
        ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes(($_ | ConvertTo-Json -Compress)))
    }
    $unsigned = $parts -join '.'
    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
    if ($null -eq $rsa) {
        throw 'An RSA certificate is required.'
    }
    try {
        $signature = $rsa.SignData(
            [Text.Encoding]::UTF8.GetBytes($unsigned),
            [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pss
        )
        return "$unsigned.$(ConvertTo-Base64Url $signature)"
    }
    finally {
        $rsa.Dispose()
    }
}

function Get-CostAccessToken {
    param(
        [Parameter(Mandatory)]$Tenant,
        [Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate
    )

    $response = Invoke-RestMethod -Method Post `
        -Uri "https://login.microsoftonline.com/$($Tenant.tenantId)/oauth2/v2.0/token" `
        -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 120 -Body @{
            client_id = $Tenant.clientId
            scope = 'https://management.azure.com/.default'
            grant_type = 'client_credentials'
            client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
            client_assertion = New-CostClientAssertion -TenantId $Tenant.tenantId -ClientId $Tenant.clientId -Certificate $Certificate
        }
    if ([string]::IsNullOrWhiteSpace($response.access_token)) {
        throw "Entra returned no access token for $($Tenant.tenantId)."
    }
    return @{
        Value = $response.access_token
        ExpiresAt = [DateTimeOffset]::UtcNow.AddSeconds([int]$response.expires_in - 120)
    }
}

function Get-CostRetryDelay {
    param($Headers, [int]$Attempt, [int]$StatusCode = 0)

    $delay = if ($StatusCode -eq 429) {
        [math]::Min(300, 30 * [math]::Pow(2, $Attempt))
    }
    else {
        [math]::Pow(2, $Attempt)
    }
    foreach ($header in $Headers) {
        if ($header.Key -ne 'Retry-After' -and
            $header.Key -notlike 'x-ms-ratelimit-microsoft.costmanagement-*-retry-after') { continue }
        foreach ($value in $header.Value) {
            $seconds = 0.0
            $date = [DateTimeOffset]::MinValue
            if ([double]::TryParse($value, [Globalization.NumberStyles]::Float,
                    [Globalization.CultureInfo]::InvariantCulture, [ref]$seconds) -and
                [double]::IsFinite($seconds) -and $seconds -ge 0) {
                $delay = [math]::Max($delay, $seconds)
            }
            elseif ([DateTimeOffset]::TryParse($value, [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$date)) {
                $delay = [math]::Max($delay, ($date - [DateTimeOffset]::UtcNow).TotalSeconds)
            }
            else {
                Write-Warning "Azure returned an invalid retry delay in $($header.Key); using backoff."
            }
        }
    }
    if ($delay -gt 300) {
        throw "Azure requested a retry delay of $delay seconds. Retry this report later."
    }
    return [int][math]::Ceiling($delay)
}

function Invoke-CostArmRequest {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [ValidateSet('Get', 'Post')][string]$Method = 'Get',
        [Parameter(Mandatory)]$Context,
        [string]$Body
    )

    $address = [uri]$Uri
    if ($address.Scheme -ne 'https' -or $address.Host -ne 'management.azure.com' -or
        $address.Port -ne 443 -or $address.UserInfo) {
        throw "Refusing to send an ARM token to an unexpected endpoint: $Uri"
    }
    for ($attempt = 0; $attempt -le 5; $attempt++) {
        if ($null -eq $Context.Token -or $Context.Token.ExpiresAt -le [DateTimeOffset]::UtcNow) {
            $Context.Token = Get-CostAccessToken -Tenant $Context.Tenant -Certificate $Context.Certificate
        }
        $parameters = @{
            Uri = $Uri
            Method = $Method
            Headers = @{ Authorization = "Bearer $($Context.Token.Value)" }
            ContentType = 'application/json'
            TimeoutSec = 120
            MaximumRedirection = 0
        }
        if ($Body) { $parameters.Body = $Body }
        try {
            return Invoke-RestMethod @parameters
        }
        catch [Microsoft.PowerShell.Commands.HttpResponseException] {
            $status = [int]$_.Exception.Response.StatusCode
            if ($attempt -eq 5 -and $status -eq 429) {
                throw [InvalidOperationException]::new(
                    'Azure continued throttling (HTTP 429) after 6 attempts. Retry the report later; this request returned no cost data.',
                    $_.Exception
                )
            }
            if ($attempt -eq 5 -or $status -notin @(401, 408, 429, 500, 502, 503, 504)) { throw }
            if ($status -eq 401) {
                if ($attempt -gt 0) { throw }
                $Context.Token = $null
                continue
            }
            $delay = Get-CostRetryDelay -Headers $_.Exception.Response.Headers -Attempt $attempt -StatusCode $status
            if ($status -eq 429) {
                $delay = [math]::Min(300, $delay + (Get-Random -Minimum 0 -Maximum 6))
            }
            Write-Warning "Azure returned HTTP $status; retrying in $delay seconds (retry $($attempt + 1)/5; $Uri)."
            Start-Sleep -Seconds $delay
        }
    }
}

function Get-CostSubscriptions {
    param([Parameter(Mandatory)]$Context)

    $next = 'https://management.azure.com/subscriptions?api-version=2022-12-01'
    $visited = @{}
    do {
        if ($visited.ContainsKey($next)) { throw 'Subscription pagination returned a repeated URL.' }
        $visited[$next] = $true
        $page = Invoke-CostArmRequest -Uri $next -Context $Context
        foreach ($subscription in $page.value) {
            if ($subscription.tenantId -eq $Context.Tenant.tenantId) {
                $subscription
            }
        }
        $next = if ($page.PSObject.Properties['nextLink']) { $page.nextLink } else { $null }
    } while ($next)
}

function Get-ResourceGroupCost {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Subscription,
        [Parameter(Mandatory)][datetime]$From,
        [Parameter(Mandatory)][datetime]$To,
        [Parameter(Mandatory)][decimal]$CostMoreThan,
        [Collections.Generic.List[object]]$SubscriptionTotals,
        [switch]$SuppressUnattributedWarning
    )

    $body = @{
        type = 'ActualCost'
        timeframe = 'Custom'
        timePeriod = @{ from = $From.ToString('o'); to = $To.ToString('o') }
        dataset = @{
            granularity = 'None'
            aggregation = @{ totalCost = @{ name = 'PreTaxCost'; function = 'Sum' } }
            grouping = @(@{ type = 'Dimension'; name = 'ResourceGroup' })
        }
    } | ConvertTo-Json -Depth 8 -Compress
    $next = "https://management.azure.com/subscriptions/$($Subscription.subscriptionId)/providers/Microsoft.CostManagement/query?api-version=2025-03-01"
    $visited = @{}
    $totals = @{}
    $currencyTotals = @{}
    do {
        if ($visited.ContainsKey($next)) { throw 'Cost pagination returned a repeated URL.' }
        $visited[$next] = $true
        $page = Invoke-CostArmRequest -Uri $next -Method Post -Context $Context -Body $body
        $columns = @($page.properties.columns | ForEach-Object { $_.name })
        $costIndex = [array]::IndexOf($columns, 'PreTaxCost')
        if ($costIndex -lt 0) { $costIndex = [array]::IndexOf($columns, 'Cost') }
        if ($costIndex -lt 0) { $costIndex = [array]::IndexOf($columns, 'totalCost') }
        $groupIndex = [array]::IndexOf($columns, 'ResourceGroup')
        $currencyIndex = [array]::IndexOf($columns, 'Currency')
        if ($costIndex -lt 0 -or $groupIndex -lt 0 -or $currencyIndex -lt 0) {
            throw 'Cost response is missing cost, ResourceGroup, or Currency columns.'
        }
        foreach ($row in $page.properties.rows) {
            if ($row.Count -ne $columns.Count -or $null -eq $row[$costIndex] -or
                [string]::IsNullOrWhiteSpace([string]$row[$currencyIndex])) {
                throw 'Cost response contains a malformed row.'
            }
            $cost = [decimal]::Parse(
                [string]$row[$costIndex],
                [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture
            )
            $currency = [string]$row[$currencyIndex]
            if (-not $currencyTotals.ContainsKey($currency)) { $currencyTotals[$currency] = [decimal]0 }
            $currencyTotals[$currency] += $cost
            $group = [string]$row[$groupIndex]
            if ([string]::IsNullOrWhiteSpace($group)) {
                if (-not $SuppressUnattributedWarning) {
                    $note = if ($null -ne $SubscriptionTotals) { ' Included in tenant totals.' } else { '' }
                    Write-Warning "Subscription $($Subscription.subscriptionId) has costs not attributed to a resource group; excluded from resource-group rows.$note"
                }
                continue
            }
            $key = "$group`0$currency"
            if (-not $totals.ContainsKey($key)) {
                $totals[$key] = [pscustomobject]@{
                    TenantId = $Context.Tenant.tenantId
                    TenantName = $Context.Tenant.tenantName
                    SubscriptionId = $Subscription.subscriptionId
                    SubscriptionName = $Subscription.displayName
                    ResourceGroup = $group
                    Cost = [decimal]0
                    Currency = $currency
                }
            }
            $totals[$key].Cost += $cost
        }
        $next = $page.properties.nextLink
    } while ($next)
    if ($null -ne $SubscriptionTotals) {
        foreach ($currency in $currencyTotals.Keys) {
            $SubscriptionTotals.Add([pscustomobject]@{
                SubscriptionId = $Subscription.subscriptionId
                Currency = $currency
                Cost = $currencyTotals[$currency]
            })
        }
    }
    $totals.Values | Where-Object { $_.Cost -gt $CostMoreThan }
}

Export-ModuleMember -Function Read-CostConfiguration, Get-CostCertificate, Get-CostSubscriptions,
    Get-ResourceGroupCost, New-CostClientAssertion, Get-CostRetryDelay

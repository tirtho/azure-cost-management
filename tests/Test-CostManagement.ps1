#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $root 'CostManagement.psm1'
$reportPath = Join-Path $root 'Get-AzureResourceGroupCost.ps1'
$setupPath = Join-Path $root 'Setup-AzureCostAccess.ps1'
$passed = 0
$failed = 0

function global:Assert-Equal {
    param($Actual, $Expected)
    if ($Actual -cne $Expected) { throw "Expected [$Expected], got [$Actual]." }
}

function global:Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern = '*')
    try { & $Action }
    catch {
        if ($_.Exception.Message -notlike $Pattern) {
            throw "Unexpected error: $($_.Exception.Message); expected $Pattern."
        }
        return
    }
    throw 'Expected an exception, but none was thrown.'
}

function Test-Case {
    param([string]$Name, [scriptblock]$Action)
    try {
        & $Action
        $script:passed++
        Write-Host "PASS $Name"
    }
    catch {
        $script:failed++
        Write-Host "FAIL ${Name}: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
    }
}

function New-TestTenant {
    [pscustomobject]@{
        tenantId = '11111111-1111-1111-1111-111111111111'
        tenantName = 'Test Tenant'
        clientId = '22222222-2222-2222-2222-222222222222'
        applicationObjectId = '33333333-3333-3333-3333-333333333333'
        certificateThumbprint = 'A' * 40
    }
}

function New-TestModule {
    Import-Module $modulePath -Force -PassThru
}

function Set-TestPages {
    param($Module, [object[]]$Pages)
    & $Module {
        param($Pages)
        $script:Pages = [Collections.Queue]::new()
        foreach ($page in $Pages) { $script:Pages.Enqueue($page) }
        $script:Requests = [Collections.Generic.List[object]]::new()
        function script:Invoke-CostArmRequest {
            param($Uri, $Method = 'Get', $Context, $Body)
            $script:Requests.Add([pscustomobject]@{ Uri = $Uri; Method = $Method; Body = $Body })
            if ($script:Pages.Count -eq 0) { throw 'Unexpected request.' }
            return $script:Pages.Dequeue()
        }
    } $Pages
}

function New-CostPage {
    param([object[]]$Rows = @(), [string]$NextLink = '')
    [pscustomobject]@{
        properties = [pscustomobject]@{
            columns = @(
                [pscustomobject]@{ name = 'Currency' },
                [pscustomobject]@{ name = 'ResourceGroup' },
                [pscustomobject]@{ name = 'PreTaxCost' }
            )
            rows = $Rows
            nextLink = $NextLink
        }
    }
}

$tenant = New-TestTenant
$context = @{ Tenant = $tenant }
$subscription = [pscustomobject]@{
    subscriptionId = '44444444-4444-4444-4444-444444444444'
    displayName = 'Test Subscription'
}
$query = @{
    Context = $context
    Subscription = $subscription
    From = [datetime]::new(2026, 10, 1, 0, 0, 0, [DateTimeKind]::Utc)
    To = [datetime]::new(2026, 10, 30, 12, 0, 0, [DateTimeKind]::Utc)
    CostMoreThan = [decimal]100
}
$temp = Join-Path ([IO.Path]::GetTempPath()) "azure-cost-tests-$([guid]::NewGuid())"
$null = New-Item -ItemType Directory -Path $temp

try {
    Test-Case 'All scripts parse' {
        foreach ($file in (Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object Extension -in '.ps1', '.psm1')) {
            $tokens = $null
            $errors = $null
            $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            Assert-Equal $errors.Count 0
        }
    }

    Test-Case 'Configuration validates identifiers, duplicates and schema' {
        $module = New-TestModule
        $path = Join-Path $temp 'tenants.json'
        $config = @{ schemaVersion = 1; tenants = @($tenant) }
        $config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path
        Assert-Equal (Read-CostConfiguration $path).tenants[0].tenantName 'Test Tenant'
        $config.tenants = @($tenant, $tenant)
        $config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path
        Assert-Throws { Read-CostConfiguration $path } '*Duplicate*'
        $config.tenants = @((New-TestTenant))
        $config.tenants[0].clientId = 'not-a-guid'
        $config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path
        Assert-Throws { Read-CostConfiguration $path } '*Invalid clientId*'
        $config.schemaVersion = 9
        $config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path
        Assert-Throws { Read-CostConfiguration $path } '*schemaVersion*'
    }

    Test-Case 'Certificate assertion has verifiable RSA signature and correct claims' {
        $module = New-TestModule
        $rsa = [Security.Cryptography.RSA]::Create(2048)
        $certificate = $null
        try {
            $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
                'CN=OfflineTest', $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256,
                [Security.Cryptography.RSASignaturePadding]::Pkcs1
            )
            $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-1), [DateTimeOffset]::UtcNow.AddDays(1))
            $jwt = New-CostClientAssertion -TenantId $tenant.tenantId -ClientId $tenant.clientId -Certificate $certificate
            $parts = $jwt.Split('.')
            function Decode-Base64Url([string]$Value) {
                $value = $Value.Replace('-', '+').Replace('_', '/')
                return ,([Convert]::FromBase64String($value.PadRight($value.Length + (4 - $value.Length % 4) % 4, '=')))
            }
            $claims = [Text.Encoding]::UTF8.GetString((Decode-Base64Url $parts[1])) | ConvertFrom-Json
            $header = [Text.Encoding]::UTF8.GetString((Decode-Base64Url $parts[0])) | ConvertFrom-Json
            Assert-Equal $header.alg 'PS256'
            Assert-Equal ([Convert]::ToHexString((Decode-Base64Url $header.'x5t#S256'))) `
                ([Convert]::ToHexString($certificate.GetCertHash([Security.Cryptography.HashAlgorithmName]::SHA256)))
            Assert-Equal $claims.aud "https://login.microsoftonline.com/$($tenant.tenantId)/oauth2/v2.0/token"
            Assert-Equal $claims.iss $tenant.clientId
            Assert-Equal $claims.sub $tenant.clientId
            Assert-Equal ($claims.exp - $claims.nbf) 360
            Assert-Equal $rsa.VerifyData(
                [Text.Encoding]::UTF8.GetBytes("$($parts[0]).$($parts[1])"),
                (Decode-Base64Url $parts[2]),
                [Security.Cryptography.HashAlgorithmName]::SHA256,
                [Security.Cryptography.RSASignaturePadding]::Pss
            ) $true
        }
        finally {
            if ($certificate) { $certificate.Dispose() }
            $rsa.Dispose()
        }
    }

    Test-Case 'Cost pages are summed before strict unrounded threshold, keeping currencies separate' {
        $module = New-TestModule
        $page1 = New-CostPage -Rows @(
            @('USD', 'rg-exact', 100),
            @('USD', 'rg-over', 100.001),
            @('USD', 'rg-split', 60),
            @('USD', 'rg-multi', 60),
            @('EUR', 'rg-multi', 60),
            @('USD', 'rg-credit', -20)
        ) -NextLink 'https://management.azure.com/next'
        $page2 = New-CostPage -Rows @(,@('USD', 'rg-split', 50))
        Set-TestPages $module @($page1, $page2)
        $rows = @(Get-ResourceGroupCost @query | Sort-Object ResourceGroup)
        Assert-Equal $rows.Count 2
        Assert-Equal $rows[0].ResourceGroup 'rg-over'
        Assert-Equal $rows[0].Cost ([decimal]'100.001')
        Assert-Equal $rows[1].Cost ([decimal]110)
        Assert-Equal $rows[1].TenantName 'Test Tenant'
        Assert-Equal (($rows[1].PSObject.Properties.Name | Sort-Object) -join ',') `
            'Cost,Currency,ResourceGroup,SubscriptionId,SubscriptionName,TenantId,TenantName'
        $requests = @(& $module { $script:Requests })
        Assert-Equal $requests.Count 2
        Assert-Equal $requests[1].Method 'Post'
        Assert-Equal $requests[0].Body $requests[1].Body
        $payload = $requests[0].Body | ConvertFrom-Json
        Assert-Equal $payload.type 'ActualCost'
        Assert-Equal $payload.timeframe 'Custom'
        Assert-Equal ([datetime]$payload.timePeriod.from).ToUniversalTime().ToString('o') '2026-10-01T00:00:00.0000000Z'
        Assert-Equal $payload.dataset.grouping[0].name 'ResourceGroup'
        Assert-Equal $payload.dataset.aggregation.totalCost.function 'Sum'
    }

    Test-Case 'Scientific-notation JSON costs preserve small charges and matching resource groups' {
        $module = New-TestModule
        $values = '[3.45E-05,1.95E-05,1.8E-05,8E-05,1.2345E+02,100]' | ConvertFrom-Json
        $page = New-CostPage -Rows @(
            @('USD', 'rg-one', $values[0]),
            @('USD', 'rg-two', $values[1]),
            @('USD', 'rg-three', $values[2]),
            @('USD', 'rg-four', $values[3]),
            @('USD', 'rg-over', $values[4]),
            @('USD', 'rg-exact', $values[5])
        )
        Set-TestPages $module @($page)
        $rows = @(Get-ResourceGroupCost @query)
        Assert-Equal $rows.Count 1
        Assert-Equal $rows[0].ResourceGroup 'rg-over'
        Assert-Equal $rows[0].Cost ([decimal]'123.45')
        $allCostsQuery = $query.Clone()
        $allCostsQuery.CostMoreThan = [decimal]0
        Set-TestPages $module @($page)
        $rows = @(Get-ResourceGroupCost @allCostsQuery)
        Assert-Equal $rows.Count 6
        $expected = @{
            'rg-one' = [decimal]'0.0000345'
            'rg-two' = [decimal]'0.0000195'
            'rg-three' = [decimal]'0.000018'
            'rg-four' = [decimal]'0.00008'
            'rg-over' = [decimal]'123.45'
            'rg-exact' = [decimal]100
        }
        foreach ($row in $rows) {
            Assert-Equal $row.Cost $expected[$row.ResourceGroup]
            Assert-Equal ($row.Cost -is [decimal]) $true
        }
    }

    Test-Case 'Scientific notation aggregates exactly across pages regardless of current culture' {
        $module = New-TestModule
        $originalCulture = [Globalization.CultureInfo]::CurrentCulture
        try {
            [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('fr-FR')
            $first = New-CostPage -Rows @(
                @('USD', 'rg-over', 100),
                @('USD', 'rg-exact', '1E+02')
            ) -NextLink 'https://management.azure.com/next'
            $second = New-CostPage -Rows @(
                @('USD', 'rg-over', 3.45E-05),
                @('USD', 'rg-over', '-1.8E-05')
            )
            Set-TestPages $module @($first, $second)
            $rows = @(Get-ResourceGroupCost @query)
            Assert-Equal $rows.Count 1
            Assert-Equal $rows[0].ResourceGroup 'rg-over'
            Assert-Equal $rows[0].Cost ([decimal]'100.0000165')
        }
        finally {
            [Globalization.CultureInfo]::CurrentCulture = $originalCulture
        }
    }

    Test-Case 'Subscription totals include below-threshold and unattributed costs without additional requests' {
        $module = New-TestModule
        $first = New-CostPage -Rows @(
            @('USD', 'rg-over', 200),
            @('USD', 'rg-small', 10),
            @('USD', '', 7.5),
            @('USD', 'rg-credit', -2)
        ) -NextLink 'https://management.azure.com/next'
        $second = New-CostPage -Rows @(
            @('USD', '', 1),
            @('EUR', 'rg-small', 50),
            @('EUR', '', 5)
        )
        Set-TestPages $module @($first, $second)
        $totals = [Collections.Generic.List[object]]::new()
        $rows = @(Get-ResourceGroupCost @query -SubscriptionTotals $totals -WarningAction SilentlyContinue)
        Assert-Equal $rows.Count 1
        Assert-Equal $rows[0].Cost ([decimal]200)
        Assert-Equal $totals.Count 2
        Assert-Equal ($totals | Where-Object Currency -eq 'USD').Cost ([decimal]'216.5')
        Assert-Equal ($totals | Where-Object Currency -eq 'EUR').Cost ([decimal]55)
        Assert-Equal @(& $module { $script:Requests }).Count 2
    }

    Test-Case 'Unattributed warning suppression preserves totals and does not suppress invalid-cost failures' {
        $module = New-TestModule
        $page = New-CostPage -Rows @(@('USD', '', 5), @('USD', 'rg-over', 120))
        Set-TestPages $module @($page)
        $totals = [Collections.Generic.List[object]]::new()
        $warnings = @()
        $rows = @(Get-ResourceGroupCost @query -SubscriptionTotals $totals `
            -SuppressUnattributedWarning -WarningVariable warnings)
        Assert-Equal $warnings.Count 0
        Assert-Equal $rows.Count 1
        Assert-Equal $totals[0].Cost ([decimal]125)
        Set-TestPages $module @((New-CostPage -Rows @(,@('USD', '', 'invalid'))))
        Assert-Throws { Get-ResourceGroupCost @query -SuppressUnattributedWarning }
    }

    Test-Case 'Failed cost pagination does not publish a subscription subtotal' {
        $module = New-TestModule
        $first = New-CostPage -Rows @(,@('USD', 'rg', 200)) -NextLink 'https://management.azure.com/next'
        $second = New-CostPage -Rows @(,@('USD', 'rg', 'invalid'))
        Set-TestPages $module @($first, $second)
        $totals = [Collections.Generic.List[object]]::new()
        Assert-Throws { Get-ResourceGroupCost @query -SubscriptionTotals $totals }
        Assert-Equal $totals.Count 0
    }

    Test-Case 'Empty cost results and unattributed costs do not create resource groups' {
        $module = New-TestModule
        Set-TestPages $module @((New-CostPage))
        Assert-Equal @(Get-ResourceGroupCost @query).Count 0
        Set-TestPages $module @((New-CostPage -Rows @(,@('USD', '', 900))))
        $warnings = @()
        Assert-Equal @(Get-ResourceGroupCost @query -WarningVariable warnings -WarningAction SilentlyContinue).Count 0
        Assert-Equal $warnings.Count 1
    }

    Test-Case 'Malformed cost columns and rows fail explicitly' {
        $module = New-TestModule
        $page = New-CostPage
        $page.properties.columns = @([pscustomobject]@{ name = 'Unknown' })
        Set-TestPages $module @($page)
        Assert-Throws { Get-ResourceGroupCost @query } '*missing*columns*'
        Set-TestPages $module @((New-CostPage -Rows @(,@('USD', 'rg', $null))))
        Assert-Throws { Get-ResourceGroupCost @query } '*malformed row*'
        foreach ($invalidCost in @('not-a-cost', 'NaN', 'Infinity', '1E+1000')) {
            Set-TestPages $module @((New-CostPage -Rows @(,@('USD', 'rg', $invalidCost))))
            Assert-Throws { Get-ResourceGroupCost @query }
        }
    }

    Test-Case 'Repeated pagination links fail rather than loop' {
        $module = New-TestModule
        $page = New-CostPage -NextLink 'https://management.azure.com/repeated'
        Set-TestPages $module @($page, $page)
        Assert-Throws { Get-ResourceGroupCost @query } '*repeated URL*'
    }

    Test-Case 'Subscription discovery follows pages and restricts tenant, retaining disabled subscriptions' {
        $module = New-TestModule
        $first = [pscustomobject]@{
            value = @([pscustomobject]@{ tenantId = $tenant.tenantId; subscriptionId = 'one'; state = 'Enabled' })
            nextLink = 'https://management.azure.com/page2'
        }
        $second = [pscustomobject]@{
            value = @(
                [pscustomobject]@{ tenantId = $tenant.tenantId; subscriptionId = 'two'; state = 'Disabled' },
                [pscustomobject]@{ tenantId = 'other-tenant'; subscriptionId = 'three' }
            )
        }
        Set-TestPages $module @($first, $second)
        $subscriptions = @(Get-CostSubscriptions $context)
        Assert-Equal $subscriptions.Count 2
        Assert-Equal $subscriptions[1].subscriptionId 'two'
    }

    Test-Case 'Retry delay honors standard and cost-specific headers and rejects excessive waits' {
        $module = New-TestModule
        $response = [Net.Http.HttpResponseMessage]::new()
        try {
            $null = $response.Headers.TryAddWithoutValidation('Retry-After', '4')
            $null = $response.Headers.TryAddWithoutValidation('x-ms-ratelimit-microsoft.costmanagement-entity-retry-after', '12')
            Assert-Equal (Get-CostRetryDelay -Headers $response.Headers -Attempt 1) 12
            $null = $response.Headers.Remove('Retry-After')
            $null = $response.Headers.TryAddWithoutValidation('Retry-After', '301')
            Assert-Throws { Get-CostRetryDelay -Headers $response.Headers -Attempt 0 } '*Retry this report later*'
        }
        finally { $response.Dispose() }
    }

    Test-Case 'ARM endpoint guard prevents credential forwarding' {
        $module = New-TestModule
        & $module {
            foreach ($uri in @('https://example.com/query', 'http://management.azure.com/query',
                'https://management.azure.com:444/query', 'https://user@management.azure.com/query')) {
                Assert-Throws { Invoke-CostArmRequest -Uri $uri -Context @{} } '*unexpected endpoint*'
            }
        }
    }

    Test-Case '429 backoff allows rate windows to recover and honors every Cost Management retry header' {
        $module = New-TestModule
        $response = [Net.Http.HttpResponseMessage]::new()
        try {
            $delays = @(0..4 | ForEach-Object { Get-CostRetryDelay -Headers $response.Headers -Attempt $_ -StatusCode 429 })
            Assert-Equal ($delays -join ',') '30,60,120,240,300'
            $null = $response.Headers.TryAddWithoutValidation('x-ms-ratelimit-microsoft.costmanagement-clienttype-retry-after', '90')
            $null = $response.Headers.TryAddWithoutValidation('x-ms-ratelimit-microsoft.costmanagement-tenant-retry-after', '120')
            $null = $response.Headers.TryAddWithoutValidation('x-ms-ratelimit-microsoft.costmanagement-qpu-retry-after', '80')
            Assert-Equal (Get-CostRetryDelay -Headers $response.Headers -Attempt 0 -StatusCode 429) 120
            $null = $response.Headers.TryAddWithoutValidation('Retry-After', '150')
            Assert-Equal (Get-CostRetryDelay -Headers $response.Headers -Attempt 0 -StatusCode 429) 150
            $null = $response.Headers.Remove('Retry-After')
            $null = $response.Headers.TryAddWithoutValidation('Retry-After', [DateTimeOffset]::UtcNow.AddSeconds(180).ToString('r'))
            $delay = Get-CostRetryDelay -Headers $response.Headers -Attempt 0 -StatusCode 429
            Assert-Equal ($delay -ge 175 -and $delay -le 180) $true
        }
        finally { $response.Dispose() }
    }

    Test-Case 'ARM requests refresh expired tokens and retry 429, but surface 403' {
        $module = New-TestModule
        & $module {
            $script:Calls = 0
            $script:TokenCalls = 0
            $script:Delays = @()
            function script:Get-CostAccessToken {
                param($Tenant, $Certificate)
                $script:TokenCalls++
                @{ Value = 'offline-token'; ExpiresAt = [DateTimeOffset]::UtcNow.AddMinutes(5) }
            }
            function script:Start-Sleep { param($Seconds) $script:Delays += $Seconds }
            function script:Get-Random { param($Minimum, $Maximum) 0 }
            function script:Invoke-RestMethod {
                param($Uri, $Method, $Headers, $ContentType, $TimeoutSec, $MaximumRedirection)
                $script:Calls++
                Assert-Equal $Headers.Authorization 'Bearer offline-token'
                if ($script:Calls -eq 1) {
                    $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::TooManyRequests)
                    $null = $response.Headers.TryAddWithoutValidation('Retry-After', '7')
                    throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Throttled', $response)
                }
                return 'ok'
            }
            $ctx = @{ Token = $null; Tenant = @{}; Certificate = $null }
            Assert-Equal (Invoke-CostArmRequest -Uri 'https://management.azure.com/test' -Context $ctx -WarningAction SilentlyContinue) 'ok'
            Assert-Equal $script:Calls 2
            Assert-Equal $script:TokenCalls 1
            Assert-Equal $script:Delays[0] 30
            $ctx.Token.ExpiresAt = [DateTimeOffset]::UtcNow.AddMinutes(-1)
            $null = Invoke-CostArmRequest -Uri 'https://management.azure.com/test' -Context $ctx
            Assert-Equal $script:TokenCalls 2
            function script:Invoke-RestMethod {
                $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::Forbidden)
                throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Forbidden test', $response)
            }
            Assert-Throws { Invoke-CostArmRequest -Uri 'https://management.azure.com/test' -Context $ctx } '*Forbidden test*'
        }
    }

    Test-Case 'Repeated 429s can recover on the last attempt without dropping the request body' {
        $module = New-TestModule
        & $module {
            $script:Calls = 0
            $script:Delays = @()
            function script:Start-Sleep { param($Seconds) $script:Delays += $Seconds }
            function script:Get-Random { param($Minimum, $Maximum) 5 }
            function script:Invoke-RestMethod {
                param($Uri, $Method, $Headers, $ContentType, $TimeoutSec, $MaximumRedirection, $Body)
                Assert-Equal $Method 'Post'
                Assert-Equal $Body '{"type":"ActualCost"}'
                $script:Calls++
                if ($script:Calls -le 5) {
                    $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::TooManyRequests)
                    $null = $response.Headers.TryAddWithoutValidation(
                        'x-ms-ratelimit-microsoft.costmanagement-clienttype-retry-after', '70'
                    )
                    throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Throttled', $response)
                }
                return 'recovered'
            }
            $ctx = @{ Token = @{ Value = 'offline-token'; ExpiresAt = [DateTimeOffset]::UtcNow.AddHours(1) } }
            $result = Invoke-CostArmRequest -Uri 'https://management.azure.com/test' -Method Post `
                -Body '{"type":"ActualCost"}' -Context $ctx -WarningAction SilentlyContinue
            Assert-Equal $result 'recovered'
            Assert-Equal $script:Calls 6
            Assert-Equal ($script:Delays -join ',') '75,75,125,245,300'
        }
    }

    Test-Case 'Persistent 429s remain a bounded explicit failure' {
        $module = New-TestModule
        & $module {
            $script:Calls = 0
            $script:Delays = @()
            function script:Start-Sleep { param($Seconds) $script:Delays += $Seconds }
            function script:Get-Random { param($Minimum, $Maximum) 0 }
            function script:Invoke-RestMethod {
                $script:Calls++
                $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::TooManyRequests)
                throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Throttled', $response)
            }
            $ctx = @{ Token = @{ Value = 'offline-token'; ExpiresAt = [DateTimeOffset]::UtcNow.AddHours(1) } }
            Assert-Throws {
                Invoke-CostArmRequest -Uri 'https://management.azure.com/test' -Context $ctx -WarningAction SilentlyContinue
            } '*continued throttling*after 6 attempts*'
            Assert-Equal $script:Calls 6
            Assert-Equal ($script:Delays -join ',') '30,60,120,240,300'
        }
    }

    Test-Case 'LastMonth queries the full previous UTC calendar month for every subscription' {
        & {
            function Import-Module {}
            function Read-CostConfiguration { [pscustomobject]@{ tenants = @($tenant) } }
            function Get-CostCertificate { 'mock-cert' }
            function Get-CostSubscriptions { $subscription; $subscription }
            $ranges = [Collections.Generic.List[object]]::new()
            function Get-ResourceGroupCost {
                param($Context, $Subscription, $From, $To, $CostMoreThan, $SubscriptionTotals)
                $ranges.Add([pscustomobject]@{ From = $From; To = $To })
                Assert-Equal $CostMoreThan ([decimal]1)
                $SubscriptionTotals.Add([pscustomobject]@{ Currency = 'USD'; Cost = [decimal]5 })
            }
            $before = [datetime]::UtcNow
            $rows = @(& $reportPath -COST_MORE_THAN 1 -LastMonth -AsObject)
            $after = [datetime]::UtcNow
            Assert-Equal $ranges.Count 2
            $from = $ranges[0].From
            $to = $ranges[0].To
            Assert-Equal $from.Kind ([DateTimeKind]::Utc)
            Assert-Equal $to.Kind ([DateTimeKind]::Utc)
            Assert-Equal $from.Day 1
            Assert-Equal $from.TimeOfDay ([timespan]::Zero)
            Assert-Equal $to ($from.AddMonths(1).AddSeconds(-1))
            $earliest = [datetime]::new($before.Year, $before.Month, 1, 0, 0, 0, [DateTimeKind]::Utc)
            $latest = [datetime]::new($after.Year, $after.Month, 1, 0, 0, 0, [DateTimeKind]::Utc)
            Assert-Equal ($from.AddMonths(1) -ge $earliest -and $from.AddMonths(1) -le $latest) $true
            Assert-Equal $ranges[1].From $from
            Assert-Equal $ranges[1].To $to
            Assert-Equal $rows.Count 1
            Assert-Equal $rows[0].Cost ([decimal]10)
            $ranges.Clear()
            $text = (& $reportPath -COST_MORE_THAN 1 -LastMonth 6>&1 | Out-String)
            Assert-Equal $text.Contains("Actual pre-tax costs: $($ranges[0].From.ToString('u')) to $($ranges[0].To.ToString('u')) (UTC)") $true
        }
    }

    Test-Case 'Report objects and partial failures preserve scope context and signal failure' {
        & {
            function Import-Module {}
            function Read-CostConfiguration { [pscustomobject]@{ tenants = @($tenant) } }
            function Get-CostCertificate { 'mock-cert' }
            function Get-CostSubscriptions {
                @(
                    [pscustomobject]@{ subscriptionId = 'good'; displayName = 'Good' },
                    [pscustomobject]@{ subscriptionId = 'bad'; displayName = 'Bad' }
                )
            }
            function Get-ResourceGroupCost {
                param($Context, $Subscription, $From, $To, $CostMoreThan, $SubscriptionTotals)
                Assert-Equal $From.Day 1
                Assert-Equal $From.Kind ([DateTimeKind]::Utc)
                Assert-Equal $From.Month $To.Month
                Assert-Equal $CostMoreThan ([decimal]100)
                if ($Subscription.subscriptionId -eq 'bad') {
                    $SubscriptionTotals.Add([pscustomobject]@{ Currency = 'USD'; Cost = 999 })
                    throw 'Simulated denied cost access'
                }
                $SubscriptionTotals.Add([pscustomobject]@{ Currency = 'USD'; Cost = [decimal]101 })
                [pscustomobject]@{
                    TenantId = $tenant.tenantId; TenantName = $tenant.tenantName
                    SubscriptionName = 'Good'; ResourceGroup = 'rg'; Currency = 'USD'; Cost = 101
                }
            }
            $captured = [Collections.Generic.List[object]]::new()
            $warnings = @()
            Assert-Throws {
                & $reportPath -COST_MORE_THAN 100 -AsObject -WarningVariable warnings -WarningAction SilentlyContinue |
                    ForEach-Object { $captured.Add($_) }
            } '*INCOMPLETE REPORT*'
            Assert-Equal $captured.Count 2
            Assert-Equal $captured[0].SubscriptionName 'Good'
            Assert-Equal $captured[1].ResourceGroup 'TENANT TOTAL'
            Assert-Equal $captured[1].Cost ([decimal]101)
            Assert-Equal $captured[1].Status 'Partial'
            $consoleMessages = [Collections.Generic.List[string]]::new()
            Assert-Throws {
                & $reportPath -COST_MORE_THAN 100 -WarningAction SilentlyContinue 6>&1 |
                    ForEach-Object { $consoleMessages.Add($_.ToString()) }
            } '*INCOMPLETE REPORT*'
            $consoleText = $consoleMessages -join "`n"
            Assert-Equal $consoleText.Contains('Status: Partial (1 failed scope(s))') $true
            Assert-Equal $consoleText.Contains('Cost read failed: Bad (bad).') $true
            Assert-Throws { & $reportPath -COST_MORE_THAN 100 -TenantId '99999999-9999-9999-9999-999999999999' } '*not configured*'
            Assert-Throws { & $reportPath -COST_MORE_THAN -1 } '*validation*'
        }
    }

    Test-Case 'Compact table puts tenant metadata in the title and no-match result is explicit' {
        & {
            function Import-Module {}
            function Read-CostConfiguration { [pscustomobject]@{ tenants = @($tenant) } }
            function Get-CostCertificate { 'mock-cert' }
            function Get-CostSubscriptions { $subscription }
            function Get-ResourceGroupCost {
                param($Context, $Subscription, $From, $To, $CostMoreThan, $SubscriptionTotals)
                $SubscriptionTotals.Add([pscustomobject]@{ Currency = 'USD'; Cost = [decimal]'105.001' })
                [pscustomobject]@{
                    TenantId = $tenant.tenantId; TenantName = $tenant.tenantName
                    SubscriptionName = $subscription.displayName; ResourceGroup = 'rg-table'
                    Currency = 'USD'; Cost = [decimal]'100.001'
                }
            }
            $text = (& $reportPath -COST_MORE_THAN 100 6>&1 | Out-String)
            foreach ($value in @('Subscription', 'Resource group',
                'Cost', 'Currency: USD', 'Status: Complete', 'TENANT TOTAL',
                $tenant.tenantId, 'Test Tenant', 'Test Subscription', 'rg-table', 'USD')) {
                Assert-Equal $text.Contains($value) $true
            }
            Assert-Equal ([regex]::Matches($text, [regex]::Escape($tenant.tenantId)).Count) 1
            $dataLines = @($text -split '\r?\n' | Where-Object { $_ -match '^Test Subscription\s+rg-table\s+100' })
            Assert-Equal $dataLines.Count 1
            Assert-Equal ($dataLines[0].Length -lt 80) $true
            Assert-Equal $dataLines[0].Contains($tenant.tenantId) $false
            Assert-Equal ($text.IndexOf('rg-table') -lt $text.IndexOf('TENANT TOTAL')) $true
            Assert-Equal ([regex]::Matches($text, '(?m)^-{20,}\r?$').Count) 0
            Assert-Equal ([regex]::Matches($text, '(?m)^={20,}\r?$').Count) 1
            $footnote = 'Footnote: Costs not attributed to a resource group are excluded from resource-group rows but included in tenant totals.'
            Assert-Equal ([regex]::Matches($text, [regex]::Escape($footnote)).Count) 1
            Assert-Equal $text.TrimEnd().EndsWith($footnote) $true
            function Get-ResourceGroupCost {}
            $empty = (& $reportPath -COST_MORE_THAN 100 6>&1 | Out-String)
            Assert-Equal $empty.Contains('No resource groups exceed the threshold.') $true
            $emptyRows = @(& $reportPath -COST_MORE_THAN 100 -AsObject)
            Assert-Equal $emptyRows.Count 1
            Assert-Equal $emptyRows[0].Cost ([decimal]0)
            Assert-Equal $emptyRows[0].Currency '(not reported)'
            Assert-Equal $emptyRows[0].Status 'Complete'
        }
    }

    Test-Case 'Console separators appear only between distinct tenant tables, not in object output' {
        & {
            $firstTenantId = $tenant.tenantId
            $secondTenant = New-TestTenant
            $secondTenant.tenantId = '55555555-5555-5555-5555-555555555555'
            $thirdTenant = New-TestTenant
            $thirdTenant.tenantId = '66666666-6666-6666-6666-666666666666'
            $configuredTenants = @($tenant, $secondTenant, $thirdTenant)
            function Import-Module {}
            function Read-CostConfiguration { [pscustomobject]@{ tenants = $configuredTenants } }
            function Get-CostCertificate { 'mock-cert' }
            function Get-CostSubscriptions { $subscription }
            function Get-ResourceGroupCost {
                param($Context, $Subscription, $From, $To, $CostMoreThan, $SubscriptionTotals)
                $SubscriptionTotals.Add([pscustomobject]@{ Currency = 'USD'; Cost = [decimal]120 })
                $SubscriptionTotals.Add([pscustomobject]@{ Currency = 'EUR'; Cost = [decimal]20 })
                [pscustomobject]@{
                    TenantId = $Context.Tenant.tenantId; TenantName = $Context.Tenant.tenantName
                    SubscriptionId = $Subscription.subscriptionId; SubscriptionName = 'One'
                    ResourceGroup = 'rg'; Currency = 'USD'; Cost = [decimal]120
                }
            }
            $text = (& $reportPath -COST_MORE_THAN 100 6>&1 | Out-String)
            $sections = $text -split '(?m)^-{20,}\r?$'
            Assert-Equal $sections.Count 3
            Assert-Equal $sections[0].Contains($firstTenantId) $true
            Assert-Equal $sections[1].Contains($secondTenant.tenantId) $true
            Assert-Equal $sections[2].Contains($thirdTenant.tenantId) $true
            foreach ($section in $sections) {
                Assert-Equal ([regex]::Matches($section, 'TENANT TOTAL').Count) 2
                Assert-Equal ([regex]::Matches($section, '(?m)^={20,}\r?$').Count) 1
                Assert-Equal $section.Contains('Currencies: EUR, USD') $true
                $lines = @($section -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                $totalLineIndex = 0
                while ($totalLineIndex -lt $lines.Count -and $lines[$totalLineIndex] -cnotmatch 'TENANT TOTAL') {
                    $totalLineIndex++
                }
                Assert-Equal ($totalLineIndex -lt $lines.Count) $true
                Assert-Equal ($lines[$totalLineIndex - 1].Trim() -match '^={20,}$') $true
            }
            $rows = @(& $reportPath -COST_MORE_THAN 100 -AsObject)
            Assert-Equal $rows.Count 9
            Assert-Equal @($rows | Where-Object { $_ -isnot [pscustomobject] }).Count 0
            Assert-Equal @($rows | Where-Object RowType -eq 'TenantTotal').Count 6
        }
    }

    Test-Case 'Long display names stay on one data line and object output keeps full names' {
        & {
            $longSubscription = 'long-sub-' + ('s' * 90)
            $longGroup = 'long-rg-' + ('r' * 90)
            function Import-Module {}
            function Read-CostConfiguration { [pscustomobject]@{ tenants = @($tenant) } }
            function Get-CostCertificate { 'mock-cert' }
            function Get-CostSubscriptions { $subscription }
            function Get-ResourceGroupCost {
                param($Context, $Subscription, $From, $To, $CostMoreThan, $SubscriptionTotals)
                $SubscriptionTotals.Add([pscustomobject]@{ Currency = 'USD'; Cost = [decimal]120 })
                [pscustomobject]@{
                    TenantId = $Context.Tenant.tenantId; TenantName = $Context.Tenant.tenantName
                    SubscriptionId = $Subscription.subscriptionId; SubscriptionName = $longSubscription
                    ResourceGroup = $longGroup; Currency = 'USD'; Cost = [decimal]120
                }
            }
            $text = (& $reportPath -COST_MORE_THAN 100 6>&1 | Out-String)
            $dataLines = @($text -split '\r?\n' | Where-Object { $_ -match '^long-sub-' })
            Assert-Equal $dataLines.Count 1
            Assert-Equal $dataLines[0].Contains('long-rg-') $true
            Assert-Equal ($dataLines[0] -match '120[.,]00\s*$') $true
            $consoleWidth = $Host.UI.RawUI.WindowSize.Width
            $expectedWidth = if ($consoleWidth -gt 0) { [math]::Max(60, $consoleWidth) } else { 120 }
            Assert-Equal ($dataLines[0].Length -le $expectedWidth) $true
            $rows = @(& $reportPath -COST_MORE_THAN 100 -AsObject)
            Assert-Equal $rows[0].SubscriptionName $longSubscription
            Assert-Equal $rows[0].ResourceGroup $longGroup
        }
    }

    Test-Case 'Report totals sum every subscription by tenant and currency, including costs below threshold' {
        $module = New-TestModule
        & {
            $firstTenantId = $tenant.tenantId
            $secondTenant = New-TestTenant
            $secondTenant.tenantId = '55555555-5555-5555-5555-555555555555'
            $secondTenant.tenantName = 'Other Tenant'
            $configuredTenants = @($tenant, $secondTenant)
            function Import-Module {}
            function Read-CostConfiguration { [pscustomobject]@{ tenants = $configuredTenants } }
            function Get-CostCertificate { 'mock-cert' }
            function Get-CostSubscriptions {
                param($Context)
                if ($Context.Tenant.tenantId -eq $firstTenantId) {
                    @(
                        [pscustomobject]@{ subscriptionId = 'one'; displayName = 'One' },
                        [pscustomobject]@{ subscriptionId = 'two'; displayName = 'Two' }
                    )
                }
                else { [pscustomobject]@{ subscriptionId = 'three'; displayName = 'Three' } }
            }
            $first = New-CostPage -Rows @(@('USD', 'rg-over', 200), @('USD', 'rg-small', 10), @('USD', '', 5))
            $second = New-CostPage -Rows @(
                @('USD', 'rg-small', 50), @('USD', '', 5), @('EUR', 'rg-small', 80), @('EUR', '', 2)
            )
            $third = New-CostPage -Rows @(,@('USD', 'rg-small', 90))
            Set-TestPages $module @($first, $second, $third)
            $reportWarnings = @()
            $rows = @(& $reportPath -COST_MORE_THAN 100 -AsObject -WarningVariable reportWarnings)
            Assert-Equal $reportWarnings.Count 0
            Assert-Equal $rows.Count 4
            $firstTenantRows = @($rows | Where-Object TenantId -eq $firstTenantId)
            Assert-Equal $firstTenantRows[0].RowType 'ResourceGroup'
            Assert-Equal $firstTenantRows[0].Cost ([decimal]200)
            Assert-Equal $firstTenantRows[1].RowType 'TenantTotal'
            Assert-Equal $firstTenantRows[2].RowType 'TenantTotal'
            $totals = @($rows | Where-Object RowType -eq 'TenantTotal')
            Assert-Equal $totals.Count 3
            $firstTenantTotals = @($totals | Where-Object TenantId -eq $tenant.tenantId)
            Assert-Equal ($firstTenantTotals | Where-Object Currency -eq 'USD').Cost ([decimal]270)
            Assert-Equal ($firstTenantTotals | Where-Object Currency -eq 'EUR').Cost ([decimal]82)
            Assert-Equal ($totals | Where-Object TenantId -eq $secondTenant.tenantId).Cost ([decimal]90)
            Assert-Equal @($totals | Where-Object Status -ne 'Complete').Count 0
            Assert-Equal (($firstTenantRows[0].PSObject.Properties.Name | Sort-Object) -join ',') `
                'Cost,Currency,ResourceGroup,RowType,Status,SubscriptionId,SubscriptionName,TenantId,TenantName'
            Assert-Equal @(& $module { $script:Requests }).Count 3
        }
    }

    Test-Case 'Failed tenant gets an unavailable partial total without contaminating another tenant total' {
        & {
            $failingThumbprint = $tenant.certificateThumbprint
            $secondTenant = New-TestTenant
            $secondTenant.tenantId = '55555555-5555-5555-5555-555555555555'
            $secondTenant.tenantName = 'Other Tenant'
            $secondTenant.certificateThumbprint = 'B' * 40
            $configuredTenants = @($tenant, $secondTenant)
            function Import-Module {}
            function Read-CostConfiguration { [pscustomobject]@{ tenants = $configuredTenants } }
            function Get-CostCertificate {
                param($Thumbprint)
                if ($Thumbprint -eq $failingThumbprint) { throw 'Certificate unavailable' }
                'mock-cert'
            }
            function Get-CostSubscriptions { $subscription }
            function Get-ResourceGroupCost {
                param($Context, $Subscription, $From, $To, $CostMoreThan, $SubscriptionTotals)
                $SubscriptionTotals.Add([pscustomobject]@{ Currency = 'USD'; Cost = [decimal]40 })
            }
            $rows = [Collections.Generic.List[object]]::new()
            Assert-Throws {
                & $reportPath -COST_MORE_THAN 100 -AsObject -WarningAction SilentlyContinue |
                    ForEach-Object { $rows.Add($_) }
            } '*INCOMPLETE REPORT*'
            Assert-Equal $rows.Count 2
            $failedTotal = $rows | Where-Object TenantId -eq $tenant.tenantId
            Assert-Equal $failedTotal.Status 'Partial'
            Assert-Equal ($null -eq $failedTotal.Cost) $true
            $completeTotal = $rows | Where-Object TenantId -eq $secondTenant.tenantId
            Assert-Equal $completeTotal.Status 'Complete'
            Assert-Equal $completeTotal.Cost ([decimal]40)
        }
    }

    Test-Case 'Setup reuses saved app and skips existing direct role, adding a missing role' {
        & {
            $configPath = Join-Path $temp 'setup.json'
            @{ schemaVersion = 1; tenants = @($tenant) } | ConvertTo-Json -Depth 5 |
                Set-Content -LiteralPath $configPath
            function Import-Module {}
            function Get-CostCertificate { 'mock-cert' }
            $azCalls = [Collections.Generic.List[object]]::new()
            function az {
                $arguments = @($args)
                $azCalls.Add($arguments)
                $global:LASTEXITCODE = 0
                $command = $arguments[0..1] -join ' '
                switch ($command) {
                    'login --tenant' { '[]' }
                    'account list' {
                        @(
                            @{ tenantId = $tenant.tenantId; id = 'sub-one'; name = 'One' },
                            @{ tenantId = $tenant.tenantId; id = 'sub-two'; name = 'Two' }
                        ) | ConvertTo-Json
                    }
                    'rest --method' {
                        if ($arguments -contains 'https://management.azure.com/tenants/page2') {
                            @{ value = @(@{ tenantId = $tenant.tenantId; displayName = 'Renamed Tenant' }) } |
                                ConvertTo-Json -Depth 4
                        }
                        else {
                            @{ value = @(); nextLink = 'https://management.azure.com/tenants/page2' } |
                                ConvertTo-Json
                        }
                    }
                    'ad app' {
                        @{ id = $tenant.applicationObjectId; appId = $tenant.clientId } | ConvertTo-Json
                    }
                    'ad sp' { @(@{ id = 'principal' }) | ConvertTo-Json -AsArray }
                    'role assignment' {
                        if ($arguments[2] -eq 'list') {
                            if ($arguments -contains '/subscriptions/sub-one') { '[{"id":"existing"}]' }
                            else { '[]' }
                        }
                        else { '{}' }
                    }
                    default { throw "Unexpected CLI command: $command" }
                }
            }
            & $setupPath -TenantId $tenant.tenantId -ConfigPath $configPath
            $roleCalls = @($azCalls | Where-Object { $_[0] -eq 'role' })
            Assert-Equal $roleCalls.Count 3
            foreach ($call in $roleCalls) {
                Assert-Equal ($call -contains '--all') $false
                $scopeIndex = [array]::IndexOf($call, '--scope')
                $subscriptionIndex = [array]::IndexOf($call, '--subscription')
                Assert-Equal ($scopeIndex -ge 0 -and $subscriptionIndex -ge 0) $true
                Assert-Equal $call[$scopeIndex + 1] "/subscriptions/$($call[$subscriptionIndex + 1])"
            }
            $creates = @($azCalls | Where-Object { $_[0] -eq 'role' -and $_[2] -eq 'create' })
            Assert-Equal $creates.Count 1
            Assert-Equal ($creates[0] -contains '/subscriptions/sub-two') $true
            Assert-Equal ($creates[0] -contains '72fafb9e-0641-4937-9268-a91bfd8191a3') $true
            Assert-Equal (Read-CostConfiguration $configPath).tenants[0].tenantName 'Renamed Tenant'
        }
    }

    Test-Case 'New setup creates certificate app and principal, persists public identifiers before RBAC' {
        & {
            $configPath = Join-Path $temp 'new-setup.json'
            function Import-Module {}
            $azCalls = [Collections.Generic.List[object]]::new()
            $bodyFiles = [Collections.Generic.List[string]]::new()
            function New-SelfSignedCertificate {
                Assert-Equal ($args -contains 'NonExportable') $true
                Assert-Equal $args[[array]::IndexOf($args, '-Provider') + 1] 'Microsoft Software Key Storage Provider'
                Assert-Equal $args[[array]::IndexOf($args, '-KeySpec') + 1] 'None'
                Assert-Equal $args[[array]::IndexOf($args, '-KeyUsage') + 1] 'DigitalSignature'
                [pscustomobject]@{
                    RawData = [byte[]]@(1, 2, 3)
                    NotBefore = [datetime]::UtcNow.AddMinutes(-1)
                    NotAfter = [datetime]::UtcNow.AddMonths(12)
                    Thumbprint = 'B' * 40
                }
            }
            function az {
                $arguments = @($args)
                $azCalls.Add($arguments)
                $global:LASTEXITCODE = 0
                $command = $arguments[0..1] -join ' '
                switch ($command) {
                    'login --tenant' { '[]' }
                    'account list' {
                        @(@{ tenantId = $tenant.tenantId; id = 'sub-new'; name = 'New' }) |
                            ConvertTo-Json -AsArray
                    }
                    'rest --method' {
                        if ($arguments -contains 'POST') {
                            $bodyFile = $arguments[[array]::IndexOf($arguments, '--body') + 1].Substring(1)
                            $bodyFiles.Add($bodyFile)
                            $payload = Get-Content -LiteralPath $bodyFile -Raw | ConvertFrom-Json
                            Assert-Equal $payload.signInAudience 'AzureADMyOrg'
                            Assert-Equal $payload.keyCredentials[0].key 'AQID'
                            Assert-Equal $payload.keyCredentials[0].usage 'Verify'
                            Assert-Equal $payload.keyCredentials[0].type 'AsymmetricX509Cert'
                            @{ id = $tenant.applicationObjectId; appId = $tenant.clientId } | ConvertTo-Json
                        }
                        else {
                            @{ value = @(@{ tenantId = $tenant.tenantId; displayName = 'New Tenant' }) } |
                                ConvertTo-Json -Depth 4
                        }
                    }
                    'ad sp' {
                        if ($arguments[2] -eq 'list') { '[]' }
                        else { '{"id":"new-principal"}' }
                    }
                    'role assignment' {
                        Assert-Equal ($arguments -contains '--all') $false
                        Assert-Equal $arguments[[array]::IndexOf($arguments, '--subscription') + 1] 'sub-new'
                        if ($arguments[2] -eq 'list') { '[]' }
                        else {
                            $saved = Read-CostConfiguration $configPath
                            Assert-Equal $saved.tenants[0].clientId $tenant.clientId
                            Assert-Equal $saved.tenants[0].certificateThumbprint ('B' * 40)
                            '{}'
                        }
                    }
                    default { throw "Unexpected CLI command: $command" }
                }
            }
            & $setupPath -TenantId @($tenant.tenantId, $tenant.tenantId) -ConfigPath $configPath
            Assert-Equal @($azCalls | Where-Object { $_[0] -eq 'login' }).Count 1
            Assert-Equal @($azCalls | Where-Object { $_[0] -eq 'rest' -and $_ -contains 'POST' }).Count 1
            Assert-Equal @($azCalls | Where-Object { $_[0] -eq 'ad' -and $_[1] -eq 'sp' -and $_[2] -eq 'create' }).Count 1
            Assert-Equal (Test-Path -LiteralPath $bodyFiles[0]) $false
        }
    }

    Test-Case 'Setup with no arguments and help aliases display the same help without side effects' {
        & {
            function Import-Module { throw 'Help must not import modules.' }
            function az { throw 'Help must not call Azure CLI.' }
            function Get-CostCertificate { throw 'Help must not access certificates.' }
            $defaultHelp = (& $setupPath) -join "`n"
            Assert-Equal $defaultHelp.Contains('Usage:') $true
            Assert-Equal ((& $setupPath --help) -join "`n") $defaultHelp
            Assert-Equal ((& $setupPath -Help) -join "`n") $defaultHelp
            Assert-Equal ((& $setupPath -h) -join "`n") $defaultHelp
            Assert-Throws { & $setupPath '--not-help' }
            foreach ($alias in 'Help', 'h', '-help') {
                $parameters = @{ $alias = $true; ConfigPath = (Join-Path $temp 'missing-help-config.json') }
                $text = (& $setupPath @parameters) -join "`n"
                Assert-Equal $text $defaultHelp
                Assert-Equal $text.Contains('Usage:') $true
                foreach ($option in 'TenantId', 'AppName', 'ConfigPath', 'CertificateValidityMonths',
                    'UseDeviceCode', 'SkipDisabledSubscriptions', 'ReactivateDisabledSubscriptions', '--help') {
                    Assert-Equal $text.Contains($option) $true
                }
                Assert-Equal (Test-Path -LiteralPath $parameters.ConfigPath) $false
            }
        }
    }

    Test-Case 'Setup rejects conflicting disabled subscription switches before signing in' {
        Assert-Throws {
            & $setupPath -TenantId $tenant.tenantId -SkipDisabledSubscriptions -ReactivateDisabledSubscriptions
        } '*cannot be combined*'
    }

    foreach ($scenario in @(
        @{ Name = 'Skip disabled subscriptions only when requested'; Skip = $true; Fail = ''; Existing = $false; AllDisabled = $false; RoleCalls = 4 },
        @{ Name = 'Default setup reports disabled grant failures but continues later subscriptions'; Skip = $false; Fail = '01-disabled'; Existing = $false; AllDisabled = $false; RoleCalls = 6 },
        @{ Name = 'Default setup can reuse existing access on disabled subscriptions'; Skip = $false; Fail = ''; Existing = $true; AllDisabled = $false; RoleCalls = 5 },
        @{ Name = 'Skipping disabled subscriptions does not hide enabled subscription failures'; Skip = $true; Fail = '02-enabled'; Existing = $false; AllDisabled = $false; RoleCalls = 4 },
        @{ Name = 'All-disabled tenant explicitly reports that no access was configured'; Skip = $true; Fail = ''; Existing = $false; AllDisabled = $true; RoleCalls = 0 },
        @{ Name = 'Reactivation targets only disabled subscriptions before granting access'; Skip = $false; Fail = ''; Existing = $false; AllDisabled = $false; RoleCalls = 6; Reactivate = $true; Activation = 'Enabled' },
        @{ Name = 'Failed reactivation does not block later subscriptions'; Skip = $false; Fail = '01-disabled'; Existing = $false; AllDisabled = $false; RoleCalls = 4; Reactivate = $true; Activation = 'Rejected' },
        @{ Name = 'Accepted reactivation is not treated as enabled while state remains disabled'; Skip = $false; Fail = '01-disabled'; Existing = $false; AllDisabled = $false; RoleCalls = 4; Reactivate = $true; Activation = 'Disabled' }
    )) {
        Test-Case $scenario.Name {
            & {
                $configPath = Join-Path $temp "subscription-states-$([guid]::NewGuid()).json"
                @{ schemaVersion = 1; tenants = @($tenant) } | ConvertTo-Json -Depth 5 |
                    Set-Content -LiteralPath $configPath
                function Import-Module {}
                function Get-CostCertificate { 'mock-cert' }
                $azCalls = [Collections.Generic.List[object]]::new()
                function az {
                    $arguments = @($args)
                    $azCalls.Add($arguments)
                    $global:LASTEXITCODE = 0
                    switch ($arguments[0..1] -join ' ') {
                        'login --tenant' { '[]' }
                        'account list' {
                            $accounts = @(
                                @{ tenantId = $tenant.tenantId; id = '01-disabled'; name = 'Disabled'; state = 'Disabled' }
                            )
                            if (-not $scenario.AllDisabled) {
                                $accounts += @(
                                    @{ tenantId = $tenant.tenantId; id = '02-enabled'; name = 'Enabled'; state = 'Enabled' },
                                    @{ tenantId = $tenant.tenantId; id = '03-enabled'; name = 'Later'; state = 'Warned' }
                                )
                            }
                            $accounts | ConvertTo-Json -AsArray
                        }
                        'rest --method' {
                            $url = $arguments[[array]::IndexOf($arguments, '--url') + 1]
                            if ($url -like '*/providers/Microsoft.Subscription/enable?*') {
                                Assert-Equal $arguments[2] 'POST'
                                Assert-Equal $url 'https://management.azure.com/subscriptions/01-disabled/providers/Microsoft.Subscription/enable?api-version=2021-10-01'
                                Assert-Equal $arguments[[array]::IndexOf($arguments, '--subscription') + 1] '01-disabled'
                                Assert-Equal @($azCalls | Where-Object { $_[0] -eq 'role' }).Count 0
                                if ($scenario.Activation -eq 'Rejected') { $global:LASTEXITCODE = 1 }
                                else { '{"subscriptionId":"01-disabled"}' }
                            }
                            elseif ($url -like '*/subscriptions/01-disabled?*') {
                                Assert-Equal $arguments[2] 'GET'
                                @{ state = $scenario.Activation } | ConvertTo-Json
                            }
                            else {
                                @{ value = @(@{ tenantId = $tenant.tenantId; displayName = 'Test Tenant' }) } |
                                    ConvertTo-Json -Depth 4
                            }
                        }
                        'ad app' {
                            @{ id = $tenant.applicationObjectId; appId = $tenant.clientId } | ConvertTo-Json
                        }
                        'ad sp' { '[{"id":"principal"}]' }
                        'role assignment' {
                            $subscriptionId = $arguments[[array]::IndexOf($arguments, '--subscription') + 1]
                            if ($arguments[2] -eq 'list') {
                                if ($scenario.Existing -and $subscriptionId -eq '01-disabled') { '[{"id":"existing"}]' }
                                else { '[]' }
                            }
                            elseif ($subscriptionId -eq $scenario.Fail) {
                                $global:LASTEXITCODE = 1
                            }
                            else { '{}' }
                        }
                        default { throw "Unexpected CLI command: $($arguments -join ' ')" }
                    }
                }
                $parameters = @{
                    TenantId = $tenant.tenantId
                    ConfigPath = $configPath
                    SkipDisabledSubscriptions = $scenario.Skip
                    WarningAction = 'Continue'
                }
                $reactivate = $scenario.ContainsKey('Reactivate') -and $scenario.Reactivate
                $parameters.ReactivateDisabledSubscriptions = $reactivate
                $warnings = [Collections.Generic.List[string]]::new()
                $messages = [Collections.Generic.List[string]]::new()
                $run = {
                    & $setupPath @parameters 3>&1 6>&1 | ForEach-Object {
                        if ($_ -is [Management.Automation.WarningRecord]) { $warnings.Add($_.Message) }
                        else { $messages.Add($_.ToString()) }
                    }
                }
                if ($scenario.Fail) {
                    Assert-Throws $run '*Setup incomplete for*'
                    Assert-Equal (($warnings -join "`n").Contains($scenario.Fail)) $true
                    Assert-Equal (($messages -join "`n").Contains('Tenant ready:')) $false
                }
                else {
                    & $run
                }
                $roleCalls = @($azCalls | Where-Object { $_[0] -eq 'role' })
                Assert-Equal $roleCalls.Count $scenario.RoleCalls
                $summaryIndex = $warnings.FindIndex([Predicate[string]]{ param($message) $message.StartsWith('SUBSCRIPTION ACCESS SUMMARY:') })
                if ($scenario.Fail -or $scenario.Skip) {
                    Assert-Equal ($summaryIndex -ge 0) $true
                    $issueId = if ($scenario.Fail) { $scenario.Fail } else { '01-disabled' }
                    $summaryRows = @($warnings | Select-Object -Skip ($summaryIndex + 1))
                    Assert-Equal $summaryRows.Count $(if ($scenario.Fail -and $scenario.Skip) { 2 } else { 1 })
                    $summaryDetails = @($summaryRows | Where-Object { $_.Contains("($issueId)") })[0]
                    Assert-Equal $summaryDetails.Contains("Tenant $($tenant.tenantId)") $true
                    Assert-Equal $summaryDetails.Contains("($issueId)") $true
                    Assert-Equal $summaryDetails.Contains('discovered state:') $true
                    Assert-Equal $summaryDetails.Contains('Its costs may be absent from the report.') $true
                    Assert-Equal $summaryDetails.Contains('rerun setup with the same configuration') $true
                    if ($scenario.Skip -and -not $scenario.Fail) {
                        Assert-Equal $summaryDetails.Contains('Skipped by request; permissions were not added or verified.') $true
                    }
                    else {
                        Assert-Equal $summaryDetails.Contains('Permissions could not be configured or verified:') $true
                        $reason = if ($reactivate -and $scenario.Activation -eq 'Disabled') {
                            "subscription state is 'Disabled'"
                        } else { 'Azure CLI failed' }
                        Assert-Equal $summaryDetails.Contains($reason) $true
                    }
                    if ($issueId -eq '01-disabled') {
                        Assert-Equal $summaryDetails.Contains('subscription Disabled (01-disabled), discovered state: Disabled') $true
                    }
                    Assert-Equal @($warnings | Select-Object -Skip ($summaryIndex + 1) |
                        Where-Object { $_ -like '*subscription Later (03-enabled)*' }).Count 0
                }
                else {
                    Assert-Equal $summaryIndex -1
                }
                $enableCalls = @($azCalls | Where-Object { $_ -contains 'POST' -and ($_[0] -eq 'rest') })
                Assert-Equal $enableCalls.Count ([int]$reactivate)
                if ($reactivate) {
                    if ($scenario.Activation -eq 'Rejected') {
                        Assert-Equal (($warnings -join "`n").Contains('Reactivation request failed')) $true
                        Assert-Equal (($messages -join "`n").Contains('Reactivation request accepted:')) $false
                    }
                    elseif ($scenario.Activation -eq 'Disabled') {
                        Assert-Equal (($warnings -join "`n").Contains("subscription state is 'Disabled'")) $true
                        Assert-Equal (($messages -join "`n").Contains('Subscription enabled:')) $false
                    }
                    else {
                        Assert-Equal (($messages -join "`n").Contains('Subscription enabled:')) $true
                    }
                }
                if ($scenario.Skip) {
                    Assert-Equal @($roleCalls | Where-Object { $_ -contains '01-disabled' }).Count 0
                    Assert-Equal (($warnings -join "`n").Contains('Skipping disabled subscription')) $true
                }
                if ($scenario.AllDisabled) {
                    Assert-Equal (($warnings -join "`n").Contains('all subscriptions were skipped')) $true
                    Assert-Equal (($messages -join "`n").Contains('0 subscriptions ready, 1 disabled subscriptions skipped')) $true
                }
                else {
                    Assert-Equal @($roleCalls | Where-Object { $_[2] -eq 'create' -and $_ -contains '03-enabled' }).Count 1
                }
                Assert-Equal (Read-CostConfiguration $configPath).tenants[0].clientId $tenant.clientId
            }
        }
    }
}
finally {
    Remove-Module CostManagement -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $temp -File | Remove-Item
    Remove-Item -LiteralPath $temp
    Remove-Item Function:\Assert-Equal, Function:\Assert-Throws
}

Write-Host "`n$passed passed; $failed failed."
if ($failed -gt 0) { throw "$failed offline test(s) failed." }

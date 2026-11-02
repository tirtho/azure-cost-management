#Requires -Version 7.2
<#
.SYNOPSIS
Creates a certificate-backed app per tenant and grants subscription Cost Management Reader access.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][guid[]]$TenantId,
    [string]$AppName = 'Azure Cost Reporter',
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'tenants.json'),
    [ValidateRange(1, 24)][int]$CertificateValidityMonths = 12,
    [switch]$UseDeviceCode,
    [switch]$SkipDisabledSubscriptions
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CostManagement.psm1') -Force
if (-not $IsWindows) { throw 'Setup requires Windows and the CurrentUser certificate store.' }
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Install Azure CLI before running setup.' }
if ($TenantId -contains [guid]::Empty) { throw 'Tenant IDs cannot be empty GUIDs.' }

function Invoke-SetupAz {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = & az @Arguments --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed (exit $LASTEXITCODE): az $($Arguments[0..1] -join ' '). See the CLI error above."
    }
    if ($output) { return ($output -join "`n" | ConvertFrom-Json) }
}

function Save-SetupConfiguration {
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($ConfigPath))
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "Configuration directory does not exist: $parent"
    }
    $temporary = Join-Path $parent ([IO.Path]::GetRandomFileName())
    try {
        $config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding utf8
        Move-Item -LiteralPath $temporary -Destination $ConfigPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
    }
}

$config = if (Test-Path -LiteralPath $ConfigPath) {
    Read-CostConfiguration -Path $ConfigPath
}
else {
    [pscustomobject]@{ schemaVersion = 1; tenants = @() }
}
$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
if (-not (Test-Path -LiteralPath (Split-Path -Parent $ConfigPath) -PathType Container)) {
    throw 'The configuration parent directory must exist.'
}
$failed = [Collections.Generic.List[string]]::new()
$roleId = '72fafb9e-0641-4937-9268-a91bfd8191a3'

foreach ($id in ($TenantId | Select-Object -Unique)) {
    $tenantKey = $id.ToString()
    try {
        Write-Host "Signing in for one-time setup: $tenantKey"
        $login = @('login', '--tenant', $tenantKey, '--allow-no-subscriptions')
        if ($UseDeviceCode) { $login += '--use-device-code' }
        $null = Invoke-SetupAz -Arguments $login
        $accounts = @(Invoke-SetupAz -Arguments @('account', 'list', '--all', '--refresh'))
        $subscriptions = @($accounts | Where-Object { $_.tenantId -eq $tenantKey } |
            Sort-Object -Property id -Unique)
        if ($subscriptions.Count -eq 0) {
            throw 'No subscriptions visible to the setup identity. Check Azure RBAC, not just Entra admin rights.'
        }
        $next = 'https://management.azure.com/tenants?api-version=2022-12-01'
        $visited = @{}
        $directory = @()
        do {
            $address = [uri]$next
            if ($address.Scheme -ne 'https' -or $address.Host -ne 'management.azure.com' -or
                $address.Port -ne 443 -or $address.UserInfo -or $visited.ContainsKey($next)) {
                throw 'Tenant discovery returned an invalid or repeated pagination URL.'
            }
            $visited[$next] = $true
            $tenantPage = Invoke-SetupAz -Arguments @('rest', '--method', 'GET', '--url', $next)
            $directory = @($tenantPage.value | Where-Object { $_.tenantId -eq $tenantKey })
            $next = if ($tenantPage.PSObject.Properties['nextLink']) { $tenantPage.nextLink } else { $null }
        } while ($next -and $directory.Count -eq 0)
        if ($directory.Count -ne 1 -or [string]::IsNullOrWhiteSpace($directory[0].displayName)) {
            throw "Could not resolve the display name for tenant $tenantKey."
        }
        $entry = @($config.tenants | Where-Object { $_.tenantId -eq $tenantKey })
        if ($entry.Count -eq 0) {
            $certificate = New-SelfSignedCertificate -Subject "CN=AzureCostReporter-$tenantKey" `
                -CertStoreLocation 'Cert:\CurrentUser\My' -KeyAlgorithm RSA -KeyLength 2048 `
                -Provider 'Microsoft Software Key Storage Provider' `
                -HashAlgorithm SHA256 -KeyExportPolicy NonExportable -KeySpec None -KeyUsage DigitalSignature `
                -NotAfter (Get-Date).AddMonths($CertificateValidityMonths)
            $applicationBody = @{
                displayName = $AppName
                signInAudience = 'AzureADMyOrg'
                keyCredentials = @(@{
                    type = 'AsymmetricX509Cert'
                    usage = 'Verify'
                    key = [Convert]::ToBase64String($certificate.RawData)
                    displayName = "Cost reporter $($certificate.Thumbprint)"
                    startDateTime = $certificate.NotBefore.ToUniversalTime().ToString('o')
                    endDateTime = $certificate.NotAfter.ToUniversalTime().ToString('o')
                })
            }
            $bodyFile = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
            try {
                $applicationBody | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $bodyFile -Encoding utf8
                $application = Invoke-SetupAz -Arguments @(
                    'rest', '--method', 'POST', '--url', 'https://graph.microsoft.com/v1.0/applications',
                    '--headers', 'Content-Type=application/json', '--body', "@$bodyFile"
                )
            }
            finally {
                if (Test-Path -LiteralPath $bodyFile) { Remove-Item -LiteralPath $bodyFile }
            }
            $tenant = [pscustomobject]@{
                tenantId = $tenantKey
                tenantName = $directory[0].displayName
                clientId = $application.appId
                applicationObjectId = $application.id
                certificateThumbprint = $certificate.Thumbprint
            }
            $config.tenants = @($config.tenants) + @($tenant)
            Save-SetupConfiguration
        }
        else {
            $tenant = $entry[0]
            $tenant.tenantName = $directory[0].displayName
            $null = Get-CostCertificate -Thumbprint $tenant.certificateThumbprint
            $application = Invoke-SetupAz -Arguments @('ad', 'app', 'show', '--id', $tenant.clientId)
            if ($application.id -ne $tenant.applicationObjectId) {
                throw 'The saved application object ID does not match Entra.'
            }
            Save-SetupConfiguration
        }
        $principals = @(Invoke-SetupAz -Arguments @(
            'ad', 'sp', 'list', '--filter', "appId eq '$($tenant.clientId)'", '--all'
        ))
        if ($principals.Count -gt 1) { throw 'Multiple service principals returned for the application.' }
        $principal = if ($principals.Count -eq 1) { $principals[0] } else {
            Invoke-SetupAz -Arguments @('ad', 'sp', 'create', '--id', $tenant.clientId)
        }
        $subscriptionFailures = [Collections.Generic.List[string]]::new()
        $readyCount = 0
        $skippedCount = 0
        foreach ($subscription in $subscriptions) {
            if ($SkipDisabledSubscriptions -and $subscription.state -eq 'Disabled') {
                $skippedCount++
                Write-Warning "Skipping disabled subscription $($subscription.name) ($($subscription.id)) in tenant ${tenantKey}. No access was checked or granted; its costs may be absent from the report."
                continue
            }
            try {
                $scope = "/subscriptions/$($subscription.id)"
                $assignments = @(Invoke-SetupAz -Arguments @(
                    'role', 'assignment', 'list', '--scope', $scope, '--subscription', $subscription.id,
                    '--query', "[?principalId=='$($principal.id)' && ends_with(roleDefinitionId, '$roleId')]"
                ))
                if ($assignments.Count -eq 0) {
                    $null = Invoke-SetupAz -Arguments @(
                        'role', 'assignment', 'create', '--assignee-object-id', $principal.id,
                        '--assignee-principal-type', 'ServicePrincipal', '--role', $roleId, '--scope', $scope,
                        '--subscription', $subscription.id
                    )
                }
                $readyCount++
                Write-Host "Cost Management Reader ready: $($subscription.name) ($($subscription.id))"
            }
            catch {
                $subscriptionFailures.Add($subscription.id)
                Write-Warning "Setup failed for tenant ${tenantKey}, subscription $($subscription.name) ($($subscription.id)): $($_.Exception.Message)"
            }
        }
        if ($subscriptionFailures.Count -gt 0) {
            throw "Subscription access setup failed for: $($subscriptionFailures -join ', '). Other subscriptions were still attempted."
        }
        if ($skippedCount -gt 0) {
            Write-Host "Tenant setup finished: $($tenant.tenantName); $readyCount subscriptions ready, $skippedCount disabled subscriptions skipped; app ID: $($tenant.clientId)"
            if ($readyCount -eq 0) {
                Write-Warning "No subscription access was configured or verified for tenant ${tenantKey}; all subscriptions were skipped."
            }
        }
        else {
            Write-Host "Tenant ready: $($tenant.tenantName); app ID: $($tenant.clientId)"
        }
    }
    catch {
        $failed.Add($tenantKey)
        Write-Warning "Setup failed for tenant ${tenantKey}: $($_.Exception.Message)"
    }
}

if ($failed.Count -gt 0) {
    throw "Setup incomplete for: $($failed -join ', '). Fix the reported errors and rerun with the same configuration."
}
Write-Host "Setup saved to $ConfigPath. Allow time for RBAC propagation before the first report."

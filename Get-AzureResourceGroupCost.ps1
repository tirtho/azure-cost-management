#Requires -Version 7.2
<#
.SYNOPSIS
Reports current-month or last-month resource group costs above COST_MORE_THAN and unfiltered per-tenant totals.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateScript({ $_ -ge 0 })][decimal]$COST_MORE_THAN,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'tenants.json'),
    [guid[]]$TenantId,
    [switch]$AsObject,
    [switch]$LastMonth
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CostManagement.psm1') -Force
$config = Read-CostConfiguration -Path $ConfigPath
$tenants = @($config.tenants)
if ($TenantId) {
    $requested = @($TenantId | ForEach-Object { $_.ToString() } | Select-Object -Unique)
    foreach ($id in $requested) {
        if ($id -notin $tenants.tenantId) { throw "Tenant $id is not configured. Run setup for that tenant first." }
    }
    $tenants = @($tenants | Where-Object { $_.tenantId -in $requested })
}
$to = [datetime]::UtcNow
$from = [datetime]::new($to.Year, $to.Month, 1, 0, 0, 0, [DateTimeKind]::Utc)
if ($LastMonth) {
    $to = $from.AddSeconds(-1)
    $from = $from.AddMonths(-1)
}
$results = [Collections.Generic.List[object]]::new()
$failures = [Collections.Generic.List[string]]::new()
$tenantReadNotes = @{}

foreach ($tenant in $tenants) {
    $tenantReadNotes[$tenant.tenantId] = [Collections.Generic.List[string]]::new()
    $tenantCosts = @{}
    $tenantFailureCount = 0
    $queriedCount = 0
    try {
        $context = @{
            Tenant = $tenant
            Certificate = Get-CostCertificate -Thumbprint $tenant.certificateThumbprint
            Token = $null
        }
        $subscriptions = @(Get-CostSubscriptions -Context $context)
        if ($subscriptions.Count -eq 0) {
            throw 'No subscriptions visible to the app. Rerun setup and verify role assignments.'
        }
    }
    catch {
        $message = "Tenant $($tenant.tenantId): $($_.Exception.Message)"
        $failures.Add($message)
        Write-Warning $message
        $tenantFailureCount++
        $tenantReadNotes[$tenant.tenantId].Add('Tenant discovery or authentication failed.')
        $subscriptions = @()
    }
    foreach ($subscription in $subscriptions) {
        try {
            $subscriptionTotals = [Collections.Generic.List[object]]::new()
            $rows = @(Get-ResourceGroupCost -Context $context -Subscription $subscription `
                -From $from -To $to -CostMoreThan $COST_MORE_THAN -SubscriptionTotals $subscriptionTotals `
                -SuppressUnattributedWarning)
            foreach ($total in $subscriptionTotals) {
                if (-not $tenantCosts.ContainsKey($total.Currency)) { $tenantCosts[$total.Currency] = [decimal]0 }
                $tenantCosts[$total.Currency] += $total.Cost
            }
            $queriedCount++
            foreach ($row in $rows) {
                $row | Add-Member -NotePropertyMembers @{ RowType = 'ResourceGroup'; Status = 'Complete' }
                $results.Add($row)
            }
        }
        catch {
            $message = "Tenant $($tenant.tenantId), subscription $($subscription.subscriptionId): $($_.Exception.Message)"
            $failures.Add($message)
            Write-Warning $message
            $tenantFailureCount++
            $tenantReadNotes[$tenant.tenantId].Add("Cost read failed: $($subscription.displayName) ($($subscription.subscriptionId)).")
        }
    }
    $currencies = @($tenantCosts.Keys)
    if ($currencies.Count -eq 0) { $currencies = @('(not reported)') }
    foreach ($currency in $currencies) {
        $cost = if ($tenantCosts.ContainsKey($currency)) { $tenantCosts[$currency] }
            elseif ($queriedCount -gt 0) { [decimal]0 }
            else { $null }
        $results.Add([pscustomobject]@{
            TenantId = $tenant.tenantId
            TenantName = $tenant.tenantName
            SubscriptionId = ''
            SubscriptionName = 'ALL SUBSCRIPTIONS'
            ResourceGroup = 'TENANT TOTAL'
            Cost = $cost
            Currency = $currency
            RowType = 'TenantTotal'
            Status = if ($tenantFailureCount -gt 0) { 'Partial' } else { 'Complete' }
        })
    }
}

$sorted = @($results | Sort-Object TenantName, TenantId,
    @{ Expression = { $_.RowType -eq 'TenantTotal' } },
    SubscriptionName, Currency, @{ Expression = 'Cost'; Descending = $true })
if ($AsObject) {
    $sorted
}
else {
    Write-Host "Actual pre-tax costs: $($from.ToString('u')) to $($to.ToString('u')) (UTC)"
    Write-Host "Resource-group filter: unrounded cost > $COST_MORE_THAN; tenant totals include all costs, including unattributed charges."
    Write-Host 'Currencies are kept separate; Partial totals exclude failed subscription queries.'
    $resourceGroupCount = @($sorted | Where-Object RowType -eq 'ResourceGroup').Count
    if ($resourceGroupCount -eq 0) {
        if ($failures.Count -eq 0) { Write-Host 'No resource groups exceed the threshold.' }
        else { Write-Host 'No matching resource-group rows were returned from the successfully queried scopes.' }
    }
    if ($sorted.Count -gt 0) {
        $consoleWidth = $Host.UI.RawUI.WindowSize.Width
        $displayWidth = if ($consoleWidth -gt 0) { [math]::Max(60, $consoleWidth) } else { 120 }
        $tableTenantIds = @($sorted.TenantId | Select-Object -Unique)
        for ($index = 0; $index -lt $tableTenantIds.Count; $index++) {
            $tenantRows = @($sorted | Where-Object TenantId -eq $tableTenantIds[$index])
            $tenantCurrencies = @($tenantRows.Currency | Sort-Object -Unique)
            $multipleCurrencies = $tenantCurrencies.Count -gt 1
            $notes = $tenantReadNotes[$tableTenantIds[$index]]
            $status = if ($notes.Count -gt 0) { "Partial ($($notes.Count) failed scope(s))" } else { 'Complete' }
            $currencyLabel = if ($multipleCurrencies) { 'Currencies' } else { 'Currency' }
            $displayRows = @($tenantRows | ForEach-Object {
                [pscustomobject]@{
                    Subscription = if ($_.RowType -eq 'TenantTotal') { 'TENANT TOTAL' } else { $_.SubscriptionName }
                    ResourceGroup = if ($_.RowType -eq 'TenantTotal') { '' } else { $_.ResourceGroup }
                    Cost = if ($null -eq $_.Cost) { '-' } else { $_.Cost.ToString('N2') }
                    Currency = $_.Currency
                    RowType = $_.RowType
                }
            })
            $subscriptionWidth = [math]::Max(12, ($displayRows.Subscription | Measure-Object -Property Length -Maximum).Maximum)
            $groupWidth = [math]::Max(14, ($displayRows.ResourceGroup | Measure-Object -Property Length -Maximum).Maximum)
            $costWidth = [math]::Max(4, ($displayRows.Cost | Measure-Object -Property Length -Maximum).Maximum)
            $currencyWidth = if ($multipleCurrencies) {
                [math]::Max(8, ($tenantCurrencies | Measure-Object -Property Length -Maximum).Maximum)
            } else { 0 }
            $gaps = if ($multipleCurrencies) { 3 } else { 2 }
            $nameBudget = $displayWidth - $costWidth - $currencyWidth - $gaps
            if ($subscriptionWidth + $groupWidth -gt $nameBudget) {
                $subscriptionWidth = [math]::Min($subscriptionWidth, [math]::Max(12, [math]::Floor($nameBudget * 0.35)))
                $groupWidth = [math]::Max(14, $nameBudget - $subscriptionWidth)
            }
            $columns = @(
                @{ Label = 'Subscription'; Expression = { $_.Subscription }; Width = [int]$subscriptionWidth },
                @{ Label = 'Resource group'; Expression = { $_.ResourceGroup }; Width = [int]$groupWidth },
                @{ Label = 'Cost'; Expression = { $_.Cost }; Alignment = 'Right'; Width = [int]$costWidth }
            )
            if ($multipleCurrencies) {
                $columns += @{ Label = 'Currency'; Expression = { $_.Currency }; Width = [int]$currencyWidth }
            }
            $tableWidth = [int]($subscriptionWidth + $groupWidth + $costWidth + $currencyWidth + $gaps)
            if ($index -gt 0) { Write-Host ('-' * $tableWidth) }
            Write-Host "Tenant: $($tenantRows[0].TenantName) ($($tableTenantIds[$index])) | ${currencyLabel}: $($tenantCurrencies -join ', ') | Status: $status"
            if ($notes.Count -gt 0) { Write-Host "Notes: $($notes -join ' ')" }
            $resourceRows = @($displayRows | Where-Object RowType -eq 'ResourceGroup')
            if ($resourceRows.Count -gt 0) {
                $table = $resourceRows | Format-Table -Property $columns | Out-String -Width $displayWidth
                Write-Host $table.Trim([char[]]"`r`n")
            }
            Write-Host ('=' * $tableWidth)
            $table = $displayRows | Where-Object RowType -eq 'TenantTotal' |
                Format-Table -Property $columns -HideTableHeaders:($resourceRows.Count -gt 0) |
                Out-String -Width $displayWidth
            Write-Host $table.Trim([char[]]"`r`n")
        }
    }
    Write-Host 'Footnote: Costs not attributed to a resource group are excluded from resource-group rows but included in tenant totals.'
}
if ($failures.Count -gt 0) {
    throw "INCOMPLETE REPORT: $($failures.Count) scope(s) failed. Any displayed/emitted results are partial. See warnings above."
}

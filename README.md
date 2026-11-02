# Multi-tenant Azure resource group cost report

PowerShell 7 scripts for one-time Entra setup and unattended month-to-date reporting.
Each tenant gets its own single-tenant app, service principal, and RSA certificate.
Only the public certificate is uploaded to Entra. The non-exportable private key
stays in the Windows **Current User > Personal** certificate store.

## Prerequisites

- Windows and PowerShell **7.2 or newer** (`pwsh`), not Windows PowerShell 5.1.
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli-windows)
  for setup only. No Az PowerShell modules are required.
- In **each tenant**, the setup user must be allowed to create app registrations
  and service principals (for example, Application Administrator), and have
  `Microsoft.Authorization/roleAssignments/write` on every target subscription
  (for example, Owner or Role Based Access Control Administrator).
  **Being a Microsoft Entra admin does not automatically grant Azure subscription access.**
  Activate eligible PIM roles first.
- Cost Management must support the subscription's offer and expose its costs:
  EA subscriptions require **AO view charges**; MCA subscriptions require the
  applicable **Azure charges** billing policy. CSP customer cost visibility may
  require the partner's policy. Azure RBAC cannot bypass billing restrictions.

The scripts target the Azure public cloud, not sovereign clouds.

## 1. Run setup once

From this directory, in PowerShell 7:

```powershell
.\Setup-AzureCostAccess.ps1 -TenantId @(
    '11111111-1111-1111-1111-111111111111',
    '22222222-2222-2222-2222-222222222222'
)
```

Replace the example IDs with your tenant IDs. Interactive admin authentication
(including MFA) is required **during setup** for each tenant. Add `-UseDeviceCode`
if browser login is not suitable and tenant policy allows device code.

Setup:

1. Signs into each tenant and discovers all subscriptions visible to the admin.
2. Gets the tenant display name from Azure Resource Manager.
3. Creates a single-tenant app with certificate credentials and a service principal.
4. Assigns **Cost Management Reader**
   (`72fafb9e-0641-4937-9268-a91bfd8191a3`) at each subscription scope.
5. Saves identifiers and certificate thumbprints to `tenants.json`.
   **No client secrets, private keys, or access tokens are stored in that file.**

No delegated Graph permissions or runtime Graph application permissions are
added to the app. Subscription cost access is controlled by Azure RBAC.

Certificate validity defaults to 12 months; use
`-CertificateValidityMonths 6` to change it (1-24 months). You can also specify
`-AppName` and `-ConfigPath`.

Keep the configuration: rerunning with the **same configuration** reuses the app
and certificate and adds missing subscription grants. It does not duplicate
existing direct role assignments or reset credentials. Configuration is saved
after app creation, before role assignment, so a partially completed setup can
be rerun. Temporary CLI payload files contain only public certificate data and
are removed. If an app is created but saving its configuration fails, note its
ID from Entra and reconcile it before retrying to avoid duplicate apps.

Setup continues to the other subscriptions after a role lookup or assignment
failure, and to the other tenants after a tenant failure, then throws an error if
any required scope failed. Resolve the warnings and rerun. Newly created apps/service principals
and RBAC assignments may need time to propagate; rerun setup if creation or
assignment fails due to replication. Cost querying may take several minutes to
become available.

**Coverage is limited to subscriptions the setup admin can discover.** For
subscriptions created later or previously inaccessible, rerun setup after the
admin has access. At runtime, subscriptions without an app role assignment are
not discoverable; the report cannot identify such missing subscriptions.

Setup uses Azure CLI's normal login cache and changes its active tenant/account.
The report does not use or change that cache.

### Certificate creation error: NTE_PROV_TYPE_NOT_DEF

The Microsoft Software Key Storage Provider is a CNG provider and requires
`-KeySpec None`, not the legacy `-KeySpec Signature`. Setup uses
`-KeyUsage DigitalSignature` to specify signing usage instead. If an earlier
script failed with `0x80090017` during certificate creation, use the updated
script and rerun the same command with the same configuration. The failing
tenant has not reached app registration; already configured tenants are reused.

### Role lookup error: group or scope are not required when --all is used

Azure CLI rejects `az role assignment list` when `--all` and `--scope` are
combined. Setup uses `--scope` without `--all`, with an explicit `--subscription`
for both role lookup and assignment. If an earlier script failed here, rerun
the updated script with the same configuration to reuse the saved app and
certificate and complete the subscription grants.

### Disabled subscriptions: ReadOnlyDisabledSubscription

Azure rejects new role assignments on disabled subscriptions. To exclude them
from setup explicitly, add `-SkipDisabledSubscriptions`:

```powershell
.\Setup-AzureCostAccess.ps1 -TenantId @(
    '11111111-1111-1111-1111-111111111111',
    '22222222-2222-2222-2222-222222222222'
) -SkipDisabledSubscriptions
```

Each subscription whose state is `Disabled` is skipped with a warning before
role lookup or assignment. Other subscription states are not excluded by this
switch. Skipped subscriptions do not make setup fail; any other role lookup or
assignment failure still does, after the remaining subscriptions are attempted.
The tenant summary distinguishes ready subscriptions from skipped ones. If all
are skipped, setup explicitly warns that no subscription access was configured
or verified for that tenant.

Without this switch, setup still checks disabled subscriptions: an existing
grant can be reused, but a missing grant cannot be created until the
subscription is re-enabled. Failures no longer block later subscriptions in
the same tenant.

Keep the same configuration to reuse apps and certificates. After re-enabling
a subscription, rerun setup to grant its missing access. This switch does not
re-enable subscriptions or filter cost reporting: a disabled subscription with
existing app access can still be queried, but one without access may be absent
from the report. An all-skipped tenant may have no subscriptions visible to the
reporting app, which the report treats as an error rather than zero cost.

## 2. Run an unattended cost report

Run as the **same Windows user on the same machine** that ran setup:

```powershell
.\Get-AzureResourceGroupCost.ps1 -COST_MORE_THAN 100
```

Example shape (illustrative values):

```text
Tenant: Contoso (11111111-1111-1111-1111-111111111111) | Currency: USD | Status: Complete
Subscription Resource group   Cost
------------ --------------   ----
Production   rg-api         215.32
=================================
TENANT TOTAL                230.00
```

To select only configured tenants:

```powershell
.\Get-AzureResourceGroupCost.ps1 -COST_MORE_THAN 100 `
    -TenantId '11111111-1111-1111-1111-111111111111'
```

For automation or CSV export, return unformatted objects:

```powershell
.\Get-AzureResourceGroupCost.ps1 -COST_MORE_THAN 100 -AsObject |
    Export-Csv -LiteralPath .\costs.csv -NoTypeInformation
```

Object fields are `TenantId`, `TenantName`, `SubscriptionId`,
`SubscriptionName`, `ResourceGroup`, `Cost` (decimal, or null if unavailable),
`Currency`, `RowType`, and `Status`. Resource-group rows have
`RowType = ResourceGroup`. Tenant totals have `RowType = TenantTotal`,
`SubscriptionName = ALL SUBSCRIPTIONS`, `ResourceGroup = TENANT TOTAL`,
and an empty `SubscriptionId`. Filter by `RowType` when processing CSVs to
avoid double-counting resource-group rows and tenant totals.
An automation run needs the configured Windows identity's user profile and
access to its certificate store. It never falls back to interactive login.

### Cost semantics and failures

- One UTC time range is captured for the run: the first day of the current
  calendar month at midnight through the start of the report.
- Uses the Cost Management Query API with **ActualCost**, summed **PreTaxCost**
  by resource group. This is not a forecast or an amortized-cost report.
- Filtering is **strictly greater than** `COST_MORE_THAN`, applied after summing
  all pages and before display rounding. A cost exactly equal to the threshold
  is excluded from resource-group rows. Negative thresholds are rejected.
- Each tenant has an unfiltered **TENANT TOTAL** row for each currency reported
  by its successfully queried subscriptions. Totals include all subscription
  costs, including below-threshold resource groups, credits, and charges not
  attributed to a resource group. They are computed from the same paginated
  responses, with no additional API calls. Totals appear after the tenant's
  resource-group rows, even if no resource group exceeds the threshold.
  Console output separates tenant tables with a dashed horizontal line and
  places an equals-sign line above each tenant's totals section. Tenant name,
  ID, currency, and read status appear once in a title. Failed read details
  appear in a notes line. Data rows contain only subscription, resource group,
  and cost, with an additional currency column for multi-currency tenants.
  Column widths are fitted to the console; very long names may be shortened
  rather than wrapped. Object and CSV output retain full names and contain
  only data rows, without titles, notes, or separators.
- A tenant total is marked `Partial` if any subscription query or tenant
  discovery fails; it sums only successful subscription responses. The report
  still throws at the end. If no subscription could be queried, the total cost
  is unavailable (`null` in objects, `-` in the table), not zero. If successful
  responses contain no cost rows, the total is zero. When no response supplies
  a currency, the placeholder `(not reported)` is shown; no currency is assumed.
- Cost values in ordinary decimal or scientific notation (for example,
  `3.45E-05`) are parsed with invariant culture and aggregated as decimals.
  Small charges are not discarded before threshold filtering. Malformed or
  out-of-range cost values still fail explicitly.
- The threshold is evaluated independently in each row's billing currency.
  USD 100 and EUR 100 are not equivalent; currencies are displayed, never
  converted or summed together.
- Charges not attributed to a resource group are excluded from resource-group
  rows, but included in tenant totals. A single generic footnote at the bottom
  of the console report explains this, instead of repeated subscription warnings.
  Object/CSV output has no footnote rows. Access, parsing, and throttling warnings
  are unchanged. Consequently, the displayed resource-group rows need not add up
  to the tenant total.
- Azure cost ingestion is delayed and values can change before invoicing.
  A successful report with no matching RGs explicitly says so.
- Subscription and cost query pagination are followed. Tokens are cached only
  in memory and renewed before expiry. HTTP throttling/transient failures are
  retried up to five times (six attempts total). HTTP 429 uses backoff of
  30, 60, 120, 240, and 300 seconds, plus up to five seconds of jitter without
  exceeding 300 seconds per wait. Every `Retry-After` and
  `x-ms-ratelimit-microsoft.costmanagement-*-retry-after` header is considered,
  including QPU, tenant, entity, and client-type limits; the longest valid wait
  wins. Other transient HTTP errors retain their shorter exponential backoff.
  A server-requested delay greater than five minutes fails explicitly rather
  than retrying too early. A throttled request may take roughly 13 minutes of
  waiting, or longer with server hints and request execution time. Persistent
  throttling is still an explicit failure, not a zero-cost result.
- A failed tenant/subscription is warned about, other scopes are still queried,
  and the script **throws at the end**, giving `pwsh -File` a nonzero exit.
  Any emitted table/objects/CSV are **partial** in this case, not a complete
  report. Callers must check the process exit code or catch the terminating error.
  Access failures are never represented as zero costs.

Tenant display names are captured during setup. Rerun setup to refresh renamed
tenants. Subscription names are discovered at report time.

### Avoid repeated full reports while Azure is throttling

Cost Management rate limits and QPU quotas can be shared with other queries in
the tenant. Repeated full runs can keep consuming those quotas. If HTTP 429
persists after retries, wait before running again rather than immediately
restarting the entire report. You can retry only the affected tenant using
`-TenantId`, although that still queries every visible subscription in it.

Microsoft [recommends calling the APIs no more than once per day](https://learn.microsoft.com/azure/cost-management-billing/costs/manage-automation#data-latency-and-rate-limits);
cost data is refreshed every four hours. The longer backoff cannot bypass a
service quota or guarantee that Azure will accept the request.

## Certificate lifecycle and removal

The key is non-exportable: do not expect to move this configuration to another
user or machine and reuse the certificate. No private-key export is needed.
Before certificate expiry, provision a replacement machine/user identity by
running setup with a **new configuration path** (creating new apps and keys),
test the report, and then remove old app role assignments and old apps in Entra.
The existing setup path intentionally does not rotate or delete credentials.
An expired/missing certificate causes a visible failure.

To decommission, remove the app's Cost Management Reader role assignments on
each subscription, delete its app/service principal in Entra, and remove only
the corresponding thumbprint from `Cert:\CurrentUser\My`. Keep the old
configuration until those identifiers are no longer needed.

Do not grant extra Graph permissions or Contributor/Owner to the reporting app
to troubleshoot a billing policy issue.

## Offline validation

No Azure changes, sign-in, external modules, or network access are needed:

```powershell
pwsh -NoProfile -File .\tests\Test-CostManagement.ps1
```

The tests cover syntax, certificate assertion signing, configuration validation,
pagination, exact threshold comparisons, currencies, retries, endpoint safety,
and report/setup orchestration with mocked Azure calls.

## Microsoft references

- [Cost Management access and billing policies](https://learn.microsoft.com/azure/cost-management-billing/costs/assign-access-acm-data)
- [Cost Management Query REST API](https://learn.microsoft.com/rest/api/cost-management/query/usage?view=rest-cost-management-2025-03-01)
- [Certificate credentials](https://learn.microsoft.com/entra/identity-platform/certificate-credentials)

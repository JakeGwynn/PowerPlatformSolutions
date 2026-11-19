# Flow run history

Choose either option to read existing cloud-flow history without changing the
source flows:

| Option | Download | Use |
| --- | --- | --- |
| Standalone PowerShell reader | [Get-FlowRunHistory.ps1](Get-FlowRunHistory.ps1) | Run locally with Windows PowerShell 5.1 or PowerShell 7. |
| Native Power Automate flow, Public cloud | [Public unmanaged solution ZIP](FlowRunHistoryCollector_Public_1_0_0_0_unmanaged.zip) | Import through Power Platform Solutions. No PowerShell or external runtime required. |
| Native Power Automate flow, standard GCC | [GCC unmanaged solution ZIP](FlowRunHistoryCollector_GCC_1_0_0_0_unmanaged.zip) | Same import process; **best effort, not live-tested in GCC**. |

Both solutions are editable and **Off/Draft by default**. Standard GCC means
GCC/Moderate, not GCC High, DoD or China.

## Import the native flow

1. Select the intended tenant/environment, open **Solutions > Import solution**,
   and import the ZIP for that cloud.
2. Map **Flow API** to a dedicated **HTTP with Microsoft Entra ID (preauthorized)**
   connection and **SharePoint reports** to an authorized SharePoint connection.
   Both must belong to the intended tenant and be usable in the target environment.
3. Set the three solution environment-variable values shown below, at import or
   through the imported solution's **Current value** fields.
4. Leave the flow off until configuration and connections are reviewed. Open/save
   the collector, then **Turn on**. After later variable changes, save or switch
   off/on to refresh the values.
5. Run it manually. Start with one flow/run and `Mode=Summary`; reports are written
   to your approved SharePoint folder.

The HTTP connection is the **preauthorized** connector, not HTTP v2, PPAPI, or a
custom OAuth connector. Use these exact connection settings:

| Setting | Public | Standard GCC |
| --- | --- | --- |
| Base Resource URL | `https://api.flow.microsoft.com` | `https://gov.api.flow.microsoft.us` |
| Microsoft Entra ID Resource URI | `https://service.flow.microsoft.com/` | `https://gov.service.flow.microsoft.us/` |
| Identity | Public Microsoft Entra ID | Public Microsoft Entra ID |

Keep the resource URI's trailing slash. Standard GCC uses **AzureCloud/public
Entra**, not AzureUSGovernment identity. The API host and token resource are
different values; an existing PPAPI-only connection is not interchangeable.

| Solution configuration | Value |
| --- | --- |
| Target tenant ID | Entra tenant GUID owning the mapped connections. Report context only; it does not retarget OAuth. |
| Report SharePoint site URL | Approved HTTPS site without a trailing slash, such as `https://YOUR-TENANT.sharepoint.com/sites/Reports`. |
| Report folder path | An **existing** site-relative library/folder path, default `/Shared Documents/FlowRunHistory`, without a trailing slash. |

Tenant/site values are not shipped. The solution includes the necessary connection
references and variable definitions; no separate configuration file is required.
HTTP connectors require the applicable **Power Automate premium entitlement**.
DLP, consent, limited delegated scopes, ownership and connection-sharing rules
still apply. Admin discovery does not grant access to every run's payloads.

### Native run inputs

| Input | Meaning |
| --- | --- |
| `EnvironmentId` | Blank uses this environment. An override must be accessible through the same authorized connection. |
| `FlowIds`, `RunIds` | Optional comma-separated flow resource IDs and run names. Blank flow IDs discovers visible personal/shared/solution flows. |
| `Status` | Optional comma-separated run statuses; independent of output mode. |
| `Mode` | `Summary`, `CallingRecordId`, `Errors`, or `All`. |
| `IncludeCallingRecordId` | Adds identity extraction to `Errors`/`All`. |
| `IdOnly` | Only with `CallingRecordId`: one-column `RecordId` CSV and a JSON array of verified ID strings. |
| `RecordSource` | `Both`, `Dataverse`, or `SharePoint`. |
| `PrimaryKeyMap` | Actual Dataverse keys, for example `{"account":"accountid"}`; not lookup fields or guessed keys. |
| `LastDays` | Default 7. Either explicit UTC boundary overrides this default. |
| `FromUtc`, `ToUtc` | UTC ISO timestamps ending in `Z`; inclusive/exclusive **run start** boundaries. Either can be open. |
| `ExportFormat` | `Both`, `CSV`, or `JSON`. |
| `AsAdmin` | Admin discovery/history when authorized, not a payload-access bypass. |
| `ExcludedFlowIds` | Additional flows to skip. The collector resolves and excludes its own resource/workflow identities. |
| `MaxWorkItems`, `MaxRuns` | Defaults 1000/100. Work limit is 1-5000; run limit is 1-10000. Hitting a cap produces explicit partial coverage. |

For failed runs over two weeks across the environment, leave `FlowIds`/`RunIds`
blank, set `Status=Failed`, `LastDays=14`, `Mode=Errors`, and use `AsAdmin` if
needed and authorized. For one run's details, supply its flow/run IDs and choose
`All`. For only triggering IDs, choose `CallingRecordId` and `IdOnly=true`.

Native JSON normally contains structured `Manifest`, `Runs`, `Operations`,
`Payloads`, `CallingRecords`, `Errors` and `Issues` arrays/objects; CSV uses
associated rows with valid nested JSON cells. Files have unique
`flow-history-...` names and are read back for byte verification. `IdOnly` writes
only IDs: no available IDs means `[]` and header-only CSV. Coverage remains in
native completion/run metadata, so empty minimal files alone do not prove a
complete scan. SharePoint item IDs are scoped to their site/list.

## Run the PowerShell reader

Download the script and run examples from its directory. Supply the environment
resource name, flow resource IDs and run **names**, not full URLs.

```powershell
$tenant = '11111111-1111-4111-8111-111111111111'
$environment = 'Default-11111111-1111-4111-8111-111111111111'
$flow = '22222222-2222-4222-8222-222222222222'
$flows = $flow, '33333333-3333-4333-8333-333333333333'
$run = '08586653536760200319026785874CU62'
$p = @{ TenantId = $tenant; EnvironmentName = $environment }

# Summary for one flow, or failures for several flows over the last seven days.
.\Get-FlowRunHistory.ps1 @p -FlowId $flow -LastDays 7
.\Get-FlowRunHistory.ps1 @p -FlowId $flows -Status Failed -LastDays 7 -Errors

# Failed runs across the environment over two weeks.
.\Get-FlowRunHistory.ps1 @p -AllFlows -AsAdmin -Status Failed -LastDays 14 -Errors

# Available full details for one run, exported directly to both formats.
.\Get-FlowRunHistory.ps1 @p -FlowId $flow -RunId $run -All `
    -CsvPath '.\run-details.csv' -JsonPath '.\run-details.json'

# Triggering IDs only; no action downloads.
.\Get-FlowRunHistory.ps1 @p -FlowId $flows -CallingRecordId -IdOnly `
    -RecordSource SharePoint -LastDays 7
.\Get-FlowRunHistory.ps1 @p -FlowId $flow -CallingRecordId -IdOnly `
    -DataversePrimaryKey @{ accounts = 'accountid' }

# Explicit time/status filters; From is inclusive, To is exclusive.
.\Get-FlowRunHistory.ps1 @p -FlowId $flows -Status Failed,Cancelled `
    -From '2026-11-01T00:00:00Z' -To '2026-11-08T00:00:00Z' -Errors

# Standard GCC: same public identity, government Flow API/resource.
.\Get-FlowRunHistory.ps1 @p -Cloud GCC -AllFlows -AsAdmin `
    -Status Failed -LastDays 7 -Errors -JsonPath '.\gcc-errors.json'

Get-Help .\Get-FlowRunHistory.ps1 -Full
```

`FlowId` and `RunId` accept arrays. Omit `FlowId` or use `AllFlows` for discovery;
`-All` controls **detail output**, not flow selection. `-Errors` does not filter
to failures. `-CallingRecordId` can combine with `-Errors`/`-All`, but `-IdOnly`
requires record-only output. Dates filter start time; `-LastDays` cannot combine
with `-From`/`-To`, which accept explicit UTC or timezone-offset timestamps.

### Script authentication and exports

`TenantId` is always explicit. Without `AccessToken`, the script uses Microsoft
user sign-in and ensures `Az.Accounts` 5.3.4 or later is available, installing
5.3.4 for **CurrentUser** if necessary. Windows PowerShell needs .NET Framework
4.7.2 or later. Organization package, proxy and execution policies still apply;
installation failure is an error, not a silent fallback.

Use `-SkipDependencyInstall` to prevent installation, `-DependencyRepository` for
an explicitly approved already-trusted HTTPS repository, or `-DeviceCode` for
device sign-in. `-UseExistingContext` deliberately reuses only a matching
tenant/user/public-identity context. Do not select AzureUSGovernment for standard
GCC.

A supplied delegated `-AccessToken` avoids module installation. Use the **Flow
resource URI in the connection table above**, not Graph, ARM or Dataverse.
The script rejects mismatched tenant/issuer/audience, expiry and app-only tokens.
Local JWT checks are safeguards; service authorization is authoritative.
Externally supplied tokens cannot be refreshed by the script. Another tenant
needs its own authorized sign-in/token; no tenant access is implied by a flag.

For optional Dataverse primary-key metadata discovery, supply `-DataverseUrl`
and, when not using the selected Az context, a separate `-DataverseAccessToken`
for that organization. Use `*.crm9.dynamics.com` in standard GCC. Only the explicit
organization receives that token; payload URLs never choose an authenticated
metadata destination.

`-CsvPath` and `-JsonPath` can be used separately or together and preserve pipeline
objects. Destination files must be new and parent directories must exist. JSON
is a structured array, including `[]`; CSV has stable headers even with no matches.
IDs-only output contains just verified IDs. Files publish only after successful
retrieval; a late error does not publish an incomplete traversal. Two file moves
are not a single transaction, and a process crash can leave private `.partial`
files. Protect exports and inspect errors before treating results as complete.

## Security and practical limits

- **Native I/O visibility:** both solutions have **no explicit Secure Inputs or
  Secure Outputs settings**. Raw API responses, payloads and signed content links
  can be visible to authorized owners/co-owners in history. Restrict ownership,
  connection sharing and report-folder access; add supported protection yourself
  if needed. OAuth, Embedded bindings, same-cloud HTTPS guards and report
  credential/link withholding remain. This does not expose protected historical
  outputs from another flow.
- **Payload handling:** signed content is fetched anonymously without forwarding
  Flow/Dataverse bearer tokens. Unknown/wrong-cloud hosts remain unavailable.
  The script blocks redirects and redacts links/Authorization values. Native
  HTTP redirect behavior is runtime-controlled; native payloads containing
  credential/link markers are conservatively withheld in full from reports.
  Business content may still be sensitive; import untrusted CSV text as text.
- **Coverage:** inspect `DetailCoverage`/`Issues` in script output or native
  `Manifest.Coverage`/`Issues`. `AvailableServiceData` is not a lifetime-completeness
  guarantee. `All` cannot recover secured, deleted or purged content. Unsupported
  action/repetition routes can produce `Partial` even when meaningful payloads
  downloaded; observed native full output retained two unavailable repetition
  collections. Child-flow histories need separate selection.
- **Record identity:** Dataverse uses canonical identity or actual primary keys,
  never arbitrary/lookup GUID guesses. Native Dataverse extraction requires
  canonical IDs or `PrimaryKeyMap`, not automatic metadata access. SharePoint
  uses a positive top-level numeric `ID` with site/list context. Unsupported,
  ambiguous or missing payloads do not yield invented IDs.
- **Service/runtime limits:** history is subject to permissions, retention and
  preview/undocumented API changes. Published cloud-flow retention is currently
  30 days; Dataverse `flowrun` storage does not replace runtime payload history.
  Native processing has bounded work/run caps, a 5000-iteration/12-hour loop
  limit and connector message/throughput limits; a work item is not a request or
  byte budget. Native execution can be slow: small observed cases ranged from
  about 3 minutes for a summary to 18 minutes for one full run and 44 minutes for
  one nested-error case. These are observations, not an SLA or performance parity
  with the script. Native file creation uses unique names, not an atomic
  create-if-absent guarantee.
- **Validation scope:** both exact portable ZIPs passed native solution staging,
  which is not target import/activation/runtime validation. Public behavior was
  exercised in one demo tenant. GCC is **best effort, not live-tested or certified**;
  GCC High/DoD/China are excluded. Native Dataverse identity blocks were checked,
  but an organic row-change source run was not observed, so native Dataverse
  event/history integration remains unverified. No second-tenant runtime claim
  is made.

Microsoft references: [government identity/service scope](https://learn.microsoft.com/en-us/power-automate/us-govt),
[Flow audiences](https://learn.microsoft.com/en-us/power-automate/oauth-authentication#audience-values),
[preauthorized HTTP connector](https://learn.microsoft.com/en-us/connectors/webcontents/),
[solution environment variables](https://learn.microsoft.com/en-us/power-automate/environment-variables),
and [cloud-flow limits](https://learn.microsoft.com/en-us/power-automate/limits-and-config).

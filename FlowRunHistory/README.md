# Flow run history

`Get-FlowRunHistory.ps1` reads existing **cloud-flow** history in Windows
PowerShell **5.1** and PowerShell **7**, without modifying flows, taking ownership,
resubmitting runs, or changing environment settings. No source-flow edits are needed.
It supports both solution and non-solution cloud flows in commercial-cloud tenants.

## Quick start

Run these examples from this directory. Replace the sample IDs with your environment
resource name and **flow resource IDs** from the Power Automate URLs, not a solution's
Dataverse `workflowid`. Run IDs are the run **names**, not GUIDs or complete URLs.

```powershell
$tenant = '11111111-1111-4111-8111-111111111111'
$environment = 'Default-11111111-1111-4111-8111-111111111111'
$flow = '22222222-2222-4222-8222-222222222222'
$run = '08586653536760200319026785874CU62'
$p = @{ TenantId = $tenant; EnvironmentName = $environment }

# Summary: no action/payload downloads.
.\Get-FlowRunHistory.ps1 @p -FlowId $flow -LastDays 7

# Failed runs for five flows over the last seven days, with actual action errors.
$flows = @(
    '22222222-2222-4222-8222-222222222222'
    '33333333-3333-4333-8333-333333333333'
    '44444444-4444-4444-8444-444444444444'
    '55555555-5555-4555-8555-555555555555'
    '66666666-6666-4666-8666-666666666666'
)
.\Get-FlowRunHistory.ps1 @p -FlowId $flows -Status Failed -LastDays 7 -Errors

# All failed runs in the environment over two weeks (administrator permissions).
.\Get-FlowRunHistory.ps1 @p -AllFlows -AsAdmin -Status Failed -LastDays 14 -Errors

# One run, including available trigger/action inputs, outputs, and repetitions.
$details = .\Get-FlowRunHistory.ps1 @p -FlowId $flow -RunId $run -All
$details | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath '.\run-details.json' -Encoding UTF8

# Multiple runs; IDs may belong to any of the selected flows.
$runs = $run, '08586653536760200319026785874CU63'
.\Get-FlowRunHistory.ps1 @p -FlowId $flows -RunId $runs -Errors

# Explicit UTC interval; also accepts ISO timestamps with a timezone offset.
.\Get-FlowRunHistory.ps1 @p -FlowId $flows -Status Failed,Cancelled `
    -From '2026-11-01T00:00:00Z' -To '2026-11-08T00:00:00Z'
```

`-All` is an **output mode**, not flow selection. Omit `-FlowId` (or use
`-AllFlows`) to discover flows. Without `-AsAdmin`, discovery unions personal
and shared flows and requests solution cloud flows; it cannot enumerate flows
hidden from the user. Admin discovery uses the `/scopes/admin/.../v2/flows` API.
An admin's ability to enumerate flows/runs **does not grant access to every
run's detailed inputs/outputs**.

## Authentication and other tenants

`-TenantId` is always required. The script never infers a home tenant or silently
switches to another tenant. Use an account authorized in the **target** tenant;
a guest needs the appropriate target-tenant access and consent.

Choose either:

1. **Existing, optional Az.Accounts module:** without `-AccessToken`, the script
   calls `Connect-AzAccount -Tenant <TenantId> -Environment AzureCloud -Scope Process`.
   To deliberately reuse a sign-in, add `-UseExistingContext`; the existing context
   must be a **User**, in the specified tenant, in **AzureCloud**. Az token
   acquisition uses that context and explicit tenant on each service request.
2. **Externally acquired delegated token:** pass `-AccessToken` as a String,
   SecureString, or token result with a `Token` property. No module is needed.
   The token must be issued for the Flow service, not Graph, ARM, or Dataverse.
   The recognized Flow audiences are `https://service.flow.microsoft.com/`
   and `https://api.flow.microsoft.com/`.

Nothing installs automatically. If you choose Az.Accounts, install it yourself
in the engine you will use, subject to your organization's installation policy.
Windows PowerShell's Az.Accounts prerequisites also apply. For example:

```powershell
Connect-AzAccount -Tenant $tenant -Environment AzureCloud -Scope Process
.\Get-FlowRunHistory.ps1 @p -UseExistingContext -FlowId $flow -Errors -LastDays 7

# Or obtain a token explicitly and use the dependency-free script path.
$token = Get-AzAccessToken -TenantId $tenant -ResourceUrl 'https://service.flow.microsoft.com/'
.\Get-FlowRunHistory.ps1 @p -AccessToken $token.Token -FlowId $flow -RunId $run -All
```

For another tenant, change **both** `TenantId` and `EnvironmentName`, then sign
in to that tenant or supply its token. Tenant/audience/expiry/delegated-token
claims are checked before requests. These local JWT checks are safeguards, **not
signature validation**; the service validates the actual token and permissions.
Opaque/encrypted tokens are not accepted. Do not put tokens in source files or
command-line literals. Externally supplied tokens cannot be refreshed by the
script; an expired token or HTTP 401 requires a fresh token. Az.Accounts can
refresh its own selected context.

The Power Automate endpoints require delegated user authorization and applicable
Flow API consent (for example `Flows.Read.All`, subject to tenant policy), plus
flow ownership/co-ownership or the permissions the service requires for the
chosen admin operation. Consent alone is not resource access. Conditional Access,
MFA, disabled public clients, and tenant consent restrictions still apply.
If the Az client cannot obtain an authorized Flow token, use an approved delegated
client/token instead; the script does not try app-only credentials or weaker
permissions. Sovereign clouds are **not** claimed as supported.

## Calling Dataverse rows and SharePoint items

```powershell
# Only triggering record identity/context, no action downloads.
$records = .\Get-FlowRunHistory.ps1 @p -FlowId $flows -LastDays 7 -CallingRecordId
$records | Select-Object FlowId,RunId,CallingRecord,Issues

# Exactly ID strings, for SharePoint item triggers.
.\Get-FlowRunHistory.ps1 @p -FlowId $flows -LastDays 7 `
    -CallingRecordId -RecordSource SharePoint -IdOnly

# Dataverse: explicitly state the ACTUAL primary key, not a lookup.
$keys = @{ accounts = 'accountid'; new_widgets = 'new_unusualprimarykey' }
.\Get-FlowRunHistory.ps1 @p -FlowId $flows -LastDays 7 `
    -CallingRecordId -RecordSource Dataverse -DataversePrimaryKey $keys -IdOnly

# Optional automatic primary-key metadata lookup in an explicitly selected org.
# With AccessToken for Flow, supply a separate token for this Dataverse origin.
$dvUrl = 'https://YOUR-ORG.crm.dynamics.com/'
$dvToken = Get-AzAccessToken -TenantId $tenant -ResourceUrl $dvUrl
.\Get-FlowRunHistory.ps1 @p -FlowId $flow -RunId $run -CallingRecordId `
    -AccessToken $token.Token -DataverseUrl $dvUrl -DataverseAccessToken $dvToken.Token

# IDs and errors together, or add CallingRecordId to All.
.\Get-FlowRunHistory.ps1 @p -FlowId $flows -Status Failed -LastDays 7 `
    -Errors -CallingRecordId -DataversePrimaryKey $keys
```

The normal record projection retains flow/run context, `CallingRecord`,
`DetailCoverage`, and `Issues`, but no full payloads. `-IdOnly` emits verified ID
strings and warns for missing/unsupported/ambiguous/excluded records; it cannot be
combined with `-All` or `-Errors`. SharePoint numeric item IDs are **not globally
unique**; retain site/list/run context when joining results across lists.

Extraction is deliberately conservative:

- **Dataverse row-change triggers:** uses top-level canonical `@odata.id` /
  `@odata.editLink`, a `PrimaryEntityName`/`PrimaryEntityId` remote execution
  context, or the actual primary-key attribute from your map / Dataverse
  `EntityDefinitions` metadata. Map keys match the runtime table logical name
  or entity-set name. Conflicting identities are ambiguous. It never searches
  arbitrary GUID properties, lookup IDs, or assumes `<tablename>id`.
- **SharePoint item/file-properties change triggers:** uses the top-level numeric
  `ID`. Site/list come from runtime `dataset`/`table`; `UniqueId` is a separate
  GUID when present. File `{Identifier}`, list GUIDs, and nested lookup IDs are
  not item IDs. Single-item polling envelopes are supported; multi-item batches
  are ambiguous, not arbitrarily assigned to a run.
- Connector/operation evidence must come from runtime inputs or their connection
  reference (whose current binding is explicitly labeled). The current flow
  definition alone cannot establish the historical trigger type. Recurrence,
  HTTP/manual/custom triggers, Dataverse business events/actions, and unsupported
  selected-record formats are reported as unsupported/unverified, not guessed.
- Missing/secure/expired/deleted outputs cannot be reconstructed without data the
  service no longer exposes. Existing flows are never modified to capture them.

Only the **explicitly supplied** `DataverseUrl` receives a Dataverse token;
payload URLs never select an authenticated organization. Metadata authentication
must match the target tenant and organization audience. Without an explicit
Dataverse token, metadata can use the Az context selected for Flow.

## Filtering, results, and completeness

`-Status` accepts arrays and is independent of output mode. `-Errors` does not
mean `-Status Failed`: it can expose a recovered retry even on a succeeded run.
Statuses are preserved as returned. A Power Automate **Terminate action** can
finish a run as Failed, Cancelled, or Succeeded; `-Status Terminated` only matches
a literal run status or exact run code `Terminated`, not every use of that action.

Dates filter **run start time**, not end time. `From <= startTime < To`.
`-LastDays` uses a fixed UTC window ending at invocation and cannot be combined
with From/To. The script sends supported single-status/date filters to the
service and rechecks every returned run locally. It follows paging rather than
assuming page order. Run IDs can be combined with all filters; a found but
filtered-out ID is not a missing ID. A nonexistent requested ID is an error.
Run names without flow IDs require searching the discovered flows.

Summary objects contain environment, flow, run, status, and UTC start/end times.
`-Errors` adds structured errors with source/action/repetition context,
code, message, and details. A null message means the service returned no message;
a generic run error never replaces a more specific action-output error.
`-All` preserves the run envelope and available operation metadata, full
input/output envelopes, retry history, nested actions, and repetition indexes.
Payload scalars and binary-content JSON envelopes remain their original shapes.
Child-flow runs must be selected separately. Raw binary responses are represented
losslessly with `$content-type` and base64 `$content`; empty text is not treated
as valid empty JSON.

Detailed modes probe both ordinary and scoped repetitions for each action, because
the current definition cannot prove a historical action's loop/scope shape. This
can be substantially more expensive than summary or record-only mode. Unsupported
repetition routes and advertised-count mismatches are explicit coverage issues.

Inspect **`DetailCoverage` and `Issues`**, not just the presence of a result.
`AvailableServiceData` means no retrieval issue was observed within the returned
service data, **not a guarantee of lifetime-complete capture**. `Partial` identifies
missing/secured/unreadable payloads, permissions, unsupported endpoints, and other
coverage gaps. Per-payload and per-repetition availability is explicit.
Action-list failure falls back to the expanded run actions, with a coverage issue;
it never silently declares that fallback complete. The current definition is
used to discover nested/loop names and is labeled as current, not historical.

These are preview/undocumented Power Automate service routes, independently
grounded in public implementations. Detailed action/repetition compatibility is
not a published Power Automate REST guarantee: the service can reject a route,
and those details are then marked unavailable/unsupported. The related Logic Apps
REST documentation describes the operation shapes, **not an authorization or
compatibility promise for Power Automate**.

All collection pages are followed, with cycle and same-origin/same-collection
guards. 408/429/500/502/503/504 and connection failures use bounded retries.
`Retry-After` seconds/dates are honored, never shortened; waits exceeding the
retry budget fail explicitly. Use `-MaxRetries`, `-RetryBudgetSeconds`,
`-RequestTimeoutSeconds`, and `-MaxPayloadMB` to bound requests. Listing/auth
failures terminate instead of pretending there were no runs. A pipeline may
already contain earlier results when a later collection/selected ID fails;
catch the terminating error before treating an export as complete.

Signed content links are fetched **without a Flow/Dataverse bearer token**.
Only HTTPS Microsoft runtime/content hosts are accepted, redirects are disabled,
and links/Authorization values are redacted from returned metadata and failures.
An unrecognized content host is blocked and reported, not automatically trusted.
Business payloads can still contain confidential data; protect exports accordingly.
The hidden loopback API override is solely for offline tests.

History is limited by service retention, permissions, secure-input/output settings,
and what was recorded. Current cloud-flow limits describe **30-day run retention**;
environment/product policies can differ. The Dataverse `flowrun` table has its own
retention/ingestion limits and does **not** replace the runtime trigger/action
payload service. No script can recover purged history or bypass secure data.

## Offline tests

No Pester or other test dependency is needed. The harness launches a loopback
HTTP fixture server in a job owned by the test and stops it afterward:

```powershell
powershell.exe -NoProfile -File .\tests\Invoke-Tests.ps1
pwsh.exe -NoProfile -File .\tests\Invoke-Tests.ps1

# Optional result artifact / focused regression subset.
pwsh.exe -NoProfile -File .\tests\Invoke-Tests.ps1 -ResultsPath "$env:TEMP\flow-history-tests.json"
pwsh.exe -NoProfile -File .\tests\Invoke-Tests.ps1 -TestName 'Errors|Dataverse|SharePoint'
```

The matrix covers single/multiple/all flow and run selection, solution inclusion,
UTC/status/rolling filters, paging on flows/runs/actions/repetitions, nested actions,
error/retry projections, no matches, throttling/auth/shape failures, safe record
extraction, payload availability, and signed-link protections. Synthetic JWTs and
an isolated Az.Accounts test double exercise tenant/audience/context selection.
**Fixture tests do not establish live API compatibility or cross-tenant access.**
Live validation requires an authorized delegated user/token, an environment,
retained run IDs, and representative Dataverse/SharePoint/loop/secured runs.

## Sources

- [PnP CLI run retrieval and anonymous content requests](https://github.com/pnp/cli-microsoft365/blob/main/src/m365/flow/commands/run/run-get.ts)
- [PnP CLI run listing, supported filters, and admin route](https://github.com/pnp/cli-microsoft365/blob/main/src/m365/flow/commands/run/run-list.ts)
- [PnP CLI flow discovery, admin v2, and solution inclusion](https://github.com/pnp/cli-microsoft365/blob/main/src/m365/flow/commands/flow-list.ts)
- [PnP CLI preview API/permission caveats](https://pnp.github.io/cli-microsoft365/cmd/flow/run/run-get/)
- [Logic Apps action collection shape](https://learn.microsoft.com/en-us/rest/api/logic/workflow-run-actions/list?view=rest-logic-2016-06-01)
- [Logic Apps repetition shape and indexes](https://learn.microsoft.com/en-us/rest/api/logic/workflow-run-action-repetitions/list?view=rest-logic-2016-06-01)
- [Dataverse connector operations](https://learn.microsoft.com/en-us/connectors/commondataserviceforapps/)
- [Dataverse table metadata queries](https://learn.microsoft.com/en-us/power-apps/developer/data-platform/webapi/query-metadata-web-api)
- [SharePoint connector operations and deleted-item IDs](https://learn.microsoft.com/en-us/connectors/sharepointonline/)
- [Cloud-flow duration and retention limits](https://learn.microsoft.com/en-us/power-automate/limits-and-config#duration-and-retention-limits)
- [Secure inputs and outputs](https://learn.microsoft.com/en-us/power-automate/how-tos-use-sensitive-input)
- [Dataverse flowrun storage, retention, and completeness](https://learn.microsoft.com/en-us/power-automate/dataverse/cloud-flow-run-metadata)

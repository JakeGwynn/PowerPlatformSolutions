# Native cloud-flow collector

`New-FlowHistoryCollector.ps1` generates a **stopped**, solution-compatible manual
Power Automate cloud flow. It does not install anything, sign in, deploy, publish,
run, grant permissions, create connections, or change existing connection references.
The source generator works in Windows PowerShell 5.1 and PowerShell 7.
**Public** remains the default. **Standard GCC (Moderate)** generation is an
explicit best-effort option, grounded in Microsoft endpoint/connector references
and offline fixtures; no GCC tenant deployment or live run is claimed.

This is a native counterpart, not an invocation of the PowerShell reader, an Azure
Function, custom OAuth connector, or JavaScript runtime. A single bounded FIFO
work queue keeps dynamic paging, actions, and repetitions within the native
500-action / eight-level nesting limits.

## Source and generated artifacts

Run the examples and test commands below from this `CloudFlow` directory.

| File | Purpose |
| --- | --- |
| `New-FlowHistoryCollector.ps1` | Offline collector generator; returns the package object and optionally writes a new JSON file. |
| `tests\Invoke-Tests.ps1` | Portable structural/generated-expression fixtures for PowerShell 5.1 and 7; optional `-ResultsPath` writes a test receipt. |
| `tests\New-CollectorTestDriver.ps1` | Offline generator for a temporary native driver with literal test inputs. Not a production runtime dependency. |
| Generated collector/driver JSON | Deployment packages with `definition` and bindings/metadata, not raw POST bodies or importable solution ZIPs. Keep bound/demo packages and reports outside the source checkout. |

Generate fresh files rather than editing or overwriting an earlier live-test
candidate. Rebind connection names, target tenant/site and solution workflow
references in each authorized target environment. Do not put access tokens,
callback URLs or signed content links into source, package parameters or tests.

## Connections and deployment

Use an explicitly authorized **target-tenant user** and independently verified
connections:

1. **HTTP with Microsoft Entra ID (preauthorized)** (`shared_webcontents`):
   dedicated connection with resource `https://service.flow.microsoft.com/`
   and base `https://api.flow.microsoft.com` for Public. **GCC uses the separate
   resource/base in the table below.** A Connected PPAPI-only connection
   with base `https://api.powerplatform.com/` is not interchangeable. Never repoint
   an existing connection reference used by other flows.
2. **SharePoint** (`shared_sharepointonline`): permission to create/read reports
   in the approved existing library/folder.
3. Ordinary native **HTTP** retrieves allowlisted signed content **anonymously**;
   it does not use either authenticated connection.

Both stored connection references use `Embedded`, not caller `Invoker` credentials.
The tenant in the generated report is explicit deployment context, not a way to
retarget a connection. Another tenant needs separately authorized target-tenant
connections. The preauthorized connector documents default-tenant and
preauthorization restrictions; do not promise arbitrary guest/cross-tenant access
or silently grant scopes/change clients to make it work.

```powershell
$p = @{
    TenantId = '11111111-1111-4111-8111-111111111111'
    SharePointSiteUrl = 'https://contoso.sharepoint.com/sites/Reports'
    ReportFolderPath = '/Shared Documents/FlowRunHistory'
}

# Portable placeholder bundle, not a directly importable solution ZIP.
.\New-FlowHistoryCollector.ps1 @p -OutputPath "$env:TEMP\collector-placeholder.json"

# Bind independently verified connection identifiers, without any API call.
.\New-FlowHistoryCollector.ps1 @p `
    -WebContentsConnectionName 'shared-webcontents-YOUR-VERIFIED-CONNECTION' `
    -SharePointConnectionName 'shared-sharepointonl-YOUR-VERIFIED-CONNECTION' `
    -OutputPath "$env:TEMP\collector-bound.json"
```

Output files must be new; no overwrite switch exists. The bundle contains
`definition`, `connectionReferences`, `displayName`, `state`, and deployment
verification metadata. It is **not** a raw Flow API POST body. An authorized
operator deploys its definition and bindings to the intended environment/solution,
creates a **new dedicated** logical reference for the HTTP connection, validates
the native definition, then activates/runs it through the supported solution
lifecycle. Solution-aware flows can reject classic `/start` with
`CannotStartUnpublishedSolutionFlow`; use the intended solution/Dataverse publish
and activation path, not an ownership workaround.

The report folder must already exist. The collector does not guess library IDs,
create folders, take ownership, resubmit/cancel runs, or mutate source records.
HTTP and preauthorized HTTP are premium capabilities. Licensing, DLP, consent,
connection sharing, Conditional Access, tenant isolation, and connector/service
limits still apply.

### Best-effort standard GCC (Moderate)

Select **`-Cloud GCC` when generating the collector**. This is not a runtime
manual input and cannot retarget an already Embedded connection or tenant.
Public is unchanged unless you select GCC. GCC High, DoD and China are not
implemented profiles and are rejected rather than inferred from a URL.

| Requirement | Public (default) | Standard GCC |
| --- | --- | --- |
| Generator selection | `-Cloud Public` or omit | `-Cloud GCC` |
| Entra authority | `https://login.microsoftonline.com` | `https://login.microsoftonline.com` |
| Az identity context, if used by the operator | `AzureCloud` | `AzureCloud`, **not** `AzureUSGovernment` |
| Dedicated HTTP connection Base Resource URL | `https://api.flow.microsoft.com` | `https://gov.api.flow.microsoft.us` |
| Dedicated HTTP connection Resource URI / Flow audience | `https://service.flow.microsoft.com/` | `https://gov.service.flow.microsoft.us/` |

Preserve the audience's trailing slash. The API **host**, Flow service audience,
and Power Apps/PPAPI audience are different contracts; do not replace the GCC
Flow resource with a token resource from an unrelated Power Apps example.
Standard GCC uses public Entra identity even though its Flow runtime/data
endpoints are government-hosted. This does **not** mean GCC High/DoD use that
identity configuration.

Shortest generation example, from this directory:

```powershell
.\New-FlowHistoryCollector.ps1 -Cloud GCC -TenantId $tenant `
    -SharePointSiteUrl 'https://YOUR-TENANT.sharepoint.com/sites/Reports' `
    -OutputPath "$env:TEMP\collector-gcc.json"
```

That package still has placeholder bindings. For a usable deployment, create or
select a **dedicated, authorized connection in the same GCC tenant/environment**
with the exact government resource/base above, and a GCC-tenant SharePoint
connection authorized for the approved existing folder. Use the actual approved
SharePoint site URL, not a guessed `.us` variant or a commercial demo site.
Supply those existing connection identifiers to the same offline generator:

```powershell
.\New-FlowHistoryCollector.ps1 -Cloud GCC -TenantId $tenant `
    -SharePointSiteUrl 'https://YOUR-TENANT.sharepoint.com/sites/Reports' `
    -WebContentsConnectionName 'shared-webcontents-YOUR-GCC-FLOW-CONNECTION' `
    -SharePointConnectionName 'shared-sharepointonl-YOUR-GCC-CONNECTION' `
    -OutputPath "$env:TEMP\collector-gcc-bound.json"
```

Deploy the definition and **same-cloud, same-tenant Embedded bindings** in the
intended GCC solution using its normal authorized lifecycle. The generator does
not verify a binding's tenant/scopes, change accounts, create connections, grant
consent, install dependencies, or deploy this package. The native test driver, if
used, must also be in that GCC solution and reference its collector workflow ID.

Microsoft's connector availability table lists **HTTP with Microsoft Entra ID
(preauthorized) as available in GCC**. Its documentation still warns about
default-tenant resources, limited delegated/preauthorization scopes and possible
consent/runtime failures. Availability is not a promise that this connection's
Flow scopes, DLP, premium licensing, network policy or tenant isolation permit
the requested history. Public resources supported by some GCC connectors are
not a reason to fall back to the commercial Flow API. No permission-grant or
custom-connector workaround is performed.

All self-identity, discovery, run/action/repetition and root/query-relative
paging URLs are generated against the selected API base. Authenticated requests
and paging admission enforce that exact HTTPS/443 host, the intended environment/
collection and no embedded credentials/fragments. GCC never silently falls back
to `api.flow.microsoft.com`.

Anonymous GCC content downloads accept only the reader-aligned government
families `*.logic.azure.us`, `*.api.gov.powerplatform.microsoft.us`,
`gov.api.flow.microsoft.us` and `*.blob.core.usgovcloudapi.net` (including each
listed base host). Public runtime/storage families and the commercial
`*.environment.api.powerplatformusercontent.com` route are not enabled in GCC.
No government user-content hostname is invented from a truncated/unknown domain.
Unknown origins remain `BlockedHost`/partial coverage, not an excuse to allow all
`*.microsoft.us`. Some government runtime suffixes are shared across services;
a matching storage suffix is not itself proof of a tenant, cloud accreditation
or authorization. Native HTTP redirect behavior remains runtime-controlled.

The package records `targetCloud`, required API/resource/public identity settings,
content families and `gccBestEffortOfflineOnly`; structured reports record
`Manifest.Cloud`. IDs-only files deliberately still contain only IDs. No manual
input, legacy connector-name normalization, actual-primary-key/SharePoint-ID
rule, report projection, privacy limit or retention guarantee is changed by
selecting GCC.

**GCC support is best effort, documentation/fixture-validated only—not
live-tested, platform-certified, or a government API-parity guarantee.** The
user did not require a live GCC test. Undocumented run/action/repetition routes,
SAS-IP restrictions, regional deployment, native save/activation or delegated
scopes may differ. The commercial demo results below do not validate GCC, and
the original privacy/partial-data/bounded-queue/latency limitations still apply.

### Native parameter-transport test harness

The classic management `POST .../triggers/manual/run` accepted but **ignored**
the JSON body in actual demo testing. Do not treat that call as proof that
`Mode`, `FlowIds`, dates or other inputs reached the collector.

The collector remains a standalone manual Button flow and also ends with the
scaffold-supported `Response` / `kind: PowerApp`. Its response contains only
safe run/report identity, requested mode, coverage and count metadata, not report
business data, signed links or raw API responses.

For automated native tests, place collector and a temporary driver in the
**same unmanaged solution**. `tests\New-CollectorTestDriver.ps1` generates a
stopped no-argument Button flow with a native `Workflow` action and a **literal**
`inputs.body`. Bind `host.workflowReferenceName` to the verified collector's
solution/Dataverse workflow GUID, not its runtime resource ID or a callback URL.
This shape is grounded in the built-in child-flow scaffold, Microsoft child-flow
guidance and a saved Microsoft sample. Actual native save/run still must verify
the binding and parameter receipt in the target environment.

```powershell
.\tests\New-CollectorTestDriver.ps1 `
    -CollectorWorkflowId '77777777-7777-4777-8777-777777777777' `
    -InputParameters @{
        FlowIds = '22222222-2222-4222-8222-222222222222'
        RunIds = '08586653536760200319026785874CU62'
        Mode = 'Errors'
        ExportFormat = 'Both'
        LastDays = 7
        MaxRuns = 10
        MaxWorkItems = 300
    } -OutputPath "$env:TEMP\collector-native-driver.json"
```

An authorized operator updates only the test driver's literal body between
cases and verifies the returned mode/run ID and independently read report
manifest. Add the driver/probe IDs to exclusions for environment-wide tests.
There is no anonymous HTTP trigger, custom connector, permanent production
test-input override, or external execution dependency.

## Manual inputs

| Input | Meaning |
| --- | --- |
| `EnvironmentId` | Blank uses this collector's `workflow().tags.environmentName`; optional override must be accessible through the same authorized tenant connection. |
| `FlowIds` | Comma-separated flow resource GUIDs. Blank discovers visible personal/shared/solution cloud flows; `AsAdmin` uses admin discovery/history. |
| `RunIds` | Optional comma-separated run **names**, not full URLs. Searches selected/discovered flows; unmatched names are reported explicitly. |
| `Status` | Optional comma-separated statuses, case-insensitive. Independent of output mode. |
| `Mode` | `Summary`, `CallingRecordId`, `Errors`, or `All`. |
| `IncludeCallingRecordId` | Adds identity extraction to detailed/error output; `CallingRecordId` mode always enables it. |
| `IdOnly` | Default false; allowed **only** with `Mode=CallingRecordId`. Writes only verified ID strings, with no context columns or JSON wrapper object. |
| `RecordSource` | `Both`, `Dataverse`, or `SharePoint`. |
| `PrimaryKeyMap` | JSON mapping **actual runtime table names** to actual primary keys, for example `{"account":"accountid","new_widget":"new_unusualprimarykey"}`. Not lookups or guessed `<name>id`. |
| `LastDays` | Default 7; used only when both explicit boundaries are blank. |
| `FromUtc`, `ToUtc` | ISO timestamps ending in `Z`. Inclusive/exclusive **run start** boundaries. Either explicit boundary suppresses the default LastDays window; the other boundary can remain open. |
| `ExportFormat` | `Both` (default), `CSV`, or `JSON`. |
| `AsAdmin` | Admin discovery/history, not an authorization bypass for detailed payloads. |
| `ExcludedFlowIds` | Additional helper/collector IDs to skip. The collector securely resolves and excludes its own runtime/resource ID and workflow alias before discovery. |
| `MaxWorkItems` | 1-5000, default 1000; bounds queued work including paging, expansion, payloads, and repetition requests. |
| `MaxRuns` | 1-10000, default 100 selected runs. |

Examples:

| Scenario | Inputs |
| --- | --- |
| Five flows' failed runs over seven days | `FlowIds`: five comma-separated IDs; `Status`: `Failed`; `LastDays`: `7`; `Mode`: `Errors`. |
| Whole-environment failures over two weeks | Blank `FlowIds`; `AsAdmin`: true; `Status`: `Failed`; `LastDays`: `14`; `Mode`: `Errors`. |
| One retained run's payloads/iterations | One `FlowIds` and `RunIds`; `Mode`: `All`; supply the desired date window so an older run is not filtered out. |
| Only calling-record projection | `Mode`: `CallingRecordId`; optional actual `PrimaryKeyMap`; no action history is requested. |
| Calling IDs and nothing else in files | `Mode`: `CallingRecordId`; `IdOnly`: true; CSV has only `RecordId`, JSON is an array of ID strings. |
| Detailed errors and calling IDs | `Mode`: `Errors`; `IncludeCallingRecordId`: true. |

`Terminated` matches a literal status or exact run code. A Terminate action can
finish as Failed, Cancelled, or Succeeded; statuses are not relabeled.
Summary mode reuses available run-list summaries; explicit run IDs require a
run-detail request. Personal/shared discovery cannot see hidden flows. Duplicate
or repeated collection URIs are bounded rather than traversed indefinitely.
Explicit flow IDs do not trigger an extra display-name inventory: `FlowDisplayName`
can be empty when no discovery metadata supplied it. Empty is an unknown name,
not evidence that the flow/run is absent.

Without explicit run names, history requests push down the validated UTC
start-date bounds and a **single supported** Succeeded/Failed/Cancelled/Running
status. Multi-status/Terminated selection remains local. Page summaries are also
preselected before queueing detail work, so clearly irrelevant successful/old
runs do not consume detail work capacity. Missing summary fields are resolved
through detail, not treated as proof of nonmatching. Every selected detail is
checked locally again; the server filter is never the sole authority.

With explicit `RunIds`, no server date/status filter or local page-date/status
preselection is applied: requested names are remembered before later detail
access/filtering. Thus a known but filtered-out run is not falsely reported missing.

The runtime `workflow().name` can differ from the Flow API/Dataverse workflow
alias. Setup securely reads **its own hosting environment's** flow by the runtime
name, verifies the returned resource ID and nonempty `workflowEntityId`, then
adds runtime name, returned name, resource ID and workflow alias to the exclusion
set. A failed/unverifiable lookup stops initialization rather than claiming safe
self-exclusion. The optional scan-environment override does not retarget this
own-identity lookup. Manifest identity fields preserve both verified IDs.

## Observed runtime and operating cost

Do **not** assume interactive latency or performance equivalence to the script.
In one Public-cloud demo tenant on November 18, 2026, small individual test cases had the
following observed timings:

| Small test case | Observed time | Scope of that observation |
| --- | --- | --- |
| Summary for one retained SharePoint run (v4) | About 2 min 50 sec | Stored JSON independently contained the one expected run. |
| Calling-record projection for the same run (v4) | About 8 min 21 sec | This v4 case completed but exposed the bare-runtime-API-name classification bug; it did **not** establish correct ID extraction. |
| Errors for one failed manual fixture with two nested iterations (v4) | About 44 min | Reported span 15:59:38Z to expanded Until end 16:43:21Z (43 min 43 sec); actual stored JSON contained specific division-by-zero messages. |
| Full payloads plus calling-record context for one SharePoint run (v6) | About 18 min 19.5 sec | Reported 17:13:43.4513524Z to 17:32:02.9908538Z span; actual ID/context and scalar JSON/CSV values verified, with `Partial` coverage for two unavailable repetition collections. |

These are individual test observations, **not an SLA, throughput benchmark,
latency prediction or diagnosed root cause**. The error snapshot processed all
40 queued items and contained 15 operation entries, 9 payload entries and
10 error entries, with `Partial` coverage and 16 explicit issues. Iteration and
expanded-action timing metadata did not establish the reason for the long span;
no unsupported retry, platform delay or loop-bug explanation is inferred.

Native action/loop orchestration and the selector design have operational costs;
metadata is intentionally re-read to avoid retaining signed links and private
envelopes in unsecurable variables. Start with one flow/run and Summary, narrow
date/status filters, explicit work/run limits, and an appropriately controlled
report folder. Expect detailed environment-wide scans to require operational
planning and actual measurements rather than extrapolating these cases. No
performance redesign or parity claim is implied by a successful native run.

## Reports and completeness

Unique file names start `flow-history-<collector-run-name>-<fresh-guid>` in the
approved folder. CSV is a stable native Table projection with context, UTC
timestamps/durations, run/operation/repetition association, record identities,
errors, payload availability, and coverage-issue rows. Nested `ContentJson` cells
are valid JSON for available objects, arrays, scalars and strings, not
`System.Object[]`. String cells are serialized by enclosing the value in an array
and stripping only that outer array, so quotes, backslashes, CRLF and Unicode
are not manually escaped or double-encoded. Unavailable payload cells are blank
and must be interpreted with their explicit availability/reason.

The separate JSON file is **structured JSON**, not a CSV surrogate:

```json
{
  "Manifest": { "SchemaVersion": "1.0", "Coverage": "Partial" },
  "Runs": [],
  "Operations": [],
  "Payloads": [],
  "CallingRecords": [],
  "Errors": [],
  "Issues": []
}
```

Join the flat arrays using `FlowId`, `RunId`, `OperationName`, `RepetitionName`
and `Side`; repetition metadata retains scope/item indexes. Payloads retain their
structured content when available and safe under the conservative export policy.
Record-only mode does not export source trigger business payloads. By default, calling-record
results retain source/association/coverage context.

With `IdOnly=true` in CallingRecordId mode, CSV is **exactly one `RecordId` column**
and JSON is a **plain array of verified ID strings**, for example `["5"]`, not the
structured report object above. Zero available IDs produces header-only CSV and
`[]`; unknown/secured/unsupported records do not become fabricated placeholders.
The native completion response (`idonly`, `recordidcount`, `coverage`) and run
manifest retain projection/count/coverage metadata even though minimal files intentionally omit it.
An empty minimal file alone does not establish full coverage. SharePoint item IDs
are list-scoped, not globally unique: keep the receipt/source context separately
when merging minimal outputs across lists or tenants.

Each created CSV/JSON file is read back through the same SharePoint connection.
The native binary response's `$content` is compared to `base64(expectedText)`.
A mismatch fails the flow; success-shaped action status alone is not proof that
the exported bytes match. Do not assume an unrelated Graph download URL works.

No matches are an ordinary empty snapshot (structured JSON arrays are empty;
CSV has its fixed headings). `AvailableServiceData` means no observed retrieval
issue, **not all-time/lossless completeness**. `Partial`, explicit issues,
unmatched run names, and queue/run-cap flags identify incomplete snapshots.
Cap exhaustion never silently means all data was captured. A native timeout or
failed export can leave one intended output file but no successful collector run;
inspect both flow status and manifest rather than relying on a filename.

The SharePoint CreateFile operation exposes no published atomic
create-if-absent parameter. Fresh run/GUID names avoid deliberately choosing an
existing report, but this is **not** the PowerShell reader's atomic
no-overwrite publication guarantee.

### Retention, service contracts and native limits

The collector uses the Power Automate runtime `Microsoft.ProcessSimple` routes
with `api-version=2016-11-01`, grounded in public implementations and the actual
demo checks. These are not a blanket stable/GA contract for every action,
repetition or tenant. Service changes, restricted delegated scopes, DLP, resource
permissions, throttling or content endpoints can limit a scan independently of
the native definition's validity.

Only history **still retained by the service** is available. Current published
cloud-flow limits describe 30-day run retention, measured from run start; product
or tenant policies can differ. The separate Dataverse `flowrun` ingestion/TTL
settings do not supply purged runtime trigger/action payloads. Date filters
cannot recover expired or secured data.

Native definition limits remain 500 actions/eight nested levels. This generator's
queue limit is at most 5,000 work items, and its Until also has an explicit
5,000-iteration / 12-hour bound. `MaxWorkItems` is **not** a byte limit, billable
action budget or strict HTTP-request count: one work item can execute several
native steps and re-read metadata. HTTP/connector actions use a four-retry
exponential policy beginning at five seconds; runtime/provider behavior still
controls applicable backoff and request timeouts. No total-run SLA or specific
cause of the observed long duration is inferred from that policy.

Connector/runtime message-size, content-throughput, request, looping and license
limits also apply. The collector accumulates reports rather than streaming
unbounded data; large payloads/scans can exceed those limits. Inspect actual
collector status, manifest and issues. A handled source failure yields explicit
partial coverage; an initialization, timeout or export failure is not a verified
complete report.

The runtime actions collection exposed nested Scope/Compose/action names in the
actual connection probe. Ordinary repetitions exposed nested action iterations;
foreach scoped repetitions exposed foreach instances. Unsupported scalar routes
can return 404/400 and remain explicit coverage issues. Current definitions are
not substituted for runtime trigger connector evidence. Unavailable/secured,
skipped, pre-evaluation-failed, expired or purged payloads are not reconstructed.
Nested shapes not exposed by the service, service drift, advertised-count
discrepancies, and linked child-flow runs need separate investigation; this is
not a blanket deep-parity or lifetime-history claim.

Dataverse identity uses canonical `@odata.id` / `@odata.editLink` or your actual
primary-key map. Conflicting identities are withheld. No third metadata connector
is silently added. The empty `00000000-0000-0000-0000-000000000000` sentinel is
not accepted as a canonical/key-map row ID or unique ID. SharePoint uses a positive top-level numeric `ID`, with
site/list context; unique GUIDs and file/lookup identifiers are not conflated.
Unsupported/ambiguous trigger formats have no fabricated record ID.
Runtime connector evidence uses the **exact final `host.apiId` path segment**.
Both modern `Microsoft.PowerApps/apis/shared_sharepointonline` and legacy
`Microsoft.Web/.../runtimes/.../apis/sharepointonline` forms are accepted, as are
the exact bare/shared Dataverse connector names. Arbitrary substrings, current
definition guesses and unknown trigger operations are not accepted as identity
evidence.

## Security

Authenticated Flow requests stay on the selected environment's HTTPS
`api.flow.microsoft.com` (Public) or `gov.api.flow.microsoft.us` (GCC) read paths.
Signed content requests are separate native
HTTP GETs with **no authentication/Authorization/cookies configured**, after
checking HTTPS/443 and Microsoft runtime/storage suffixes. The new
`*.environment.api.powerplatformusercontent.com` route is **Public-only** and restricted to
`/storage/powerautomate/automations/`; GCC uses only its explicit government
families listed above. Unknown/wrong-cloud hosts, credentials, fragments and
non-HTTPS/nonstandard-port URLs are rejected. No unsupported redirect-disable option is
invented: native HTTP redirect behavior remains runtime-controlled.

**The generator does not attach manual `secureData` to variable/control actions.**
Actual native activation rejected SetVariable security configuration. Omitting
unsupported protection does not mean every variable is secure.
Queue entries contain IDs, sides, and authenticated metadata selectors, never raw
operation properties, signed payload links, or full private API responses. Metadata
is re-read into supported secured actions when needed; this costs additional read
calls. Repetition selectors re-read their actual collection page and select by
name, rather than inventing an individual-repetition endpoint.

Full metadata, signed URIs and raw downloaded payloads remain in secured
Compose/HTTP/connector/data-operation outputs. A signed URI is resolved inside a
secured Compose and passed directly to the secured anonymous HTTP action, not
stored in a queue/variable. Trigger identity accumulation contains only whitelisted
scalar connector/table/site/list/ID fields, not trigger bodies. Compose/Parse JSON/
Response use **inputs only**, because those types reject explicit Secure Outputs.
Supported connector/HTTP/data actions additionally request Secure Outputs.
Foreach control loops iterate **indices**, not raw objects, and are sequential.

**Intended report/business data is accumulated in native variables and can be
visible in collector run history to owners/co-owners.** Secure-step taint might
hide some downstream values, but inherited taint is not a verified confidentiality
boundary and is not relied on as a guarantee. Keep collector ownership, run-history
access and connections tightly controlled in addition to the report folder ACL.
If that exposure is unacceptable, do not use this native collector for sensitive
payloads; use the independently controlled PowerShell reader instead. Actual
native save/activation and run-history inspection are required: static validation
does not establish platform confidentiality behavior.

Exports whitelist metadata rather than dumping `inputsLink`, `outputsLink`,
authentication objects, paging links, or raw service error responses. Payloads
containing authentication, cookie/password/API-key, link or signature markers are **withheld in full**, with
availability/reason/coverage issues, rather than pretending native expressions
can safely implement arbitrary recursive secret redaction. Secure private trigger
payloads can still yield only verified calling IDs; specific error messages have
their own marker guard. Business payloads can nevertheless contain confidential
data unrelated to those markers. Protect the report folder and import untrusted
CSV values as text to avoid spreadsheet formula execution.

Secure-taint propagation can hide a final Compose even when it references only
an authenticated action's status code. Do not bypass that protection or diagnose
the absence of an outputs link as an authentication/host failure. Locate reports
through their approved folder/run prefix and independently authorized storage
metadata instead.

## Validation

```powershell
powershell.exe -NoProfile -File .\tests\Invoke-Tests.ps1
pwsh.exe -NoProfile -File .\tests\Invoke-Tests.ps1
powershell.exe -NoProfile -File .\tests\Invoke-Tests.ps1 -Cloud GCC
pwsh.exe -NoProfile -File .\tests\Invoke-Tests.ps1 -Cloud GCC
pwsh.exe -NoProfile -File .\tests\Invoke-Tests.ps1 -ResultsPath "$env:TEMP\native-collector-tests.json"
```

Tests check action/nesting bounds, unique names/scope references, sequential
index loops, connector/read-only boundaries, supported security configurations,
all generated WDL expression syntax, and fixtures that evaluate the generated
selection/time/identity/secret/CSV/read-back expressions. The evaluator is
deliberately test-only and does **not** emulate the native workflow runtime,
OAuth, connector contracts, DLP, tenant permission, or service paging end-to-end.
The same suite runs under both selected cloud profiles. GCC fixtures evaluate
every generated route and relative paging form, public identity/government
audience binding metadata, authenticated/content origin rejection, manifest
labeling and cloud-independent record extraction, and compare the profiles to
the existing reader's mapping. They do not connect to a tenant or certify
government service behavior.

The separate small connection probe was statically accepted by FlowAgent but
actual activation found the ParseJson Secure Outputs restriction; source/tests
now enforce that type-specific rule. The coordinator's demo-tenant probe then
verified real preauthorized Flow reads, SharePoint create/read-back, nested action
discovery and two actual repetitions. Those facts do not themselves establish
full collector runtime correctness, a second tenant, or a national cloud.
Keep actual collector test receipts separate from offline fixture results.
Actual full-collector save validation also rejected literal array operands inside
native JSON condition functions. The generator now uses WDL `createArray(...)`
expression strings for enum membership; tests inspect native condition operand
shapes separately from expression-string syntax.
Subsequent native activation rejected `secureData` on SetVariable. The generator
now uses an explicit supported action-type allowlist, no manual variable/control
security configuration, selector-only work items and minimal identity accumulation.
Tests reject direct raw response/signed-link copies into mutable variable actions.
This is not a claim that accumulated report business data is hidden from co-owners.

Coordinated v4 live checks additionally verified genuine native child input
transport, one-run Summary, an admin 14-day summary with three known failed runs
and verified collector/helper exclusion, empty JSON/header-only CSV for no matches,
explicit cap/`Partial` behavior, specific nested/repetition error messages, and
full SharePoint-source payload export with typed scalar strings by
independently decoding the **intended exported files** through the authorized
SharePoint connector. The full-payload case contained two operations/four payloads;
both actual Compose input/output JSON values and both parsed CSV `ContentJson`
cells yielded the source string `test`. Missing variable-action content links
were not treated as evidence of empty variables.

The updated v6 definition passed actual native activation. Independently parsed
intended files then verified the legacy SharePoint calling ID as the **string**
`"5"`: minimal JSON was exactly `["5"]`, and CSV contained exactly one `RecordId`
column and one row `5`. The native caller returned CallingRecordId mode,
IDs-only true, verified-ID/selected-run counts of one and
`AvailableServiceData` coverage. This closes the actual legacy-classification/
minimal-projection case, not just its offline fixture.

A separate v6 multi-flow UTC/Failed summary's actual JSON contained the exact
November 18 inclusive / November 19 exclusive UTC window, three known failed
manual-fixture runs, no SharePoint success, 9/9 queued/processed work and no
issues. Start-time assertions use the report's `StartTimeUtc` field; JSON readers
that auto-convert ISO timestamps must preserve/normalize UTC types rather than
mistaking a reader conversion for a collector failure.

V6 full-payload/context acceptance also passed independently read stored files:
the legacy SharePoint identity was `Available` with ID `"5"` and matching site/
list context; two operation/four payload entries retained the actual Compose
input/output strings `test`, and both CSV JSON cells decoded to `test`. Coverage
was honestly **`Partial` with two `CollectionUnavailable` repetition-route
issues**, not a claim that every possible repetition was captured.

The v6 multi-flow/multi-explicit-run case returned exactly the two expected
flow/run pairs (SharePoint success plus manual failure), no false unmatched IDs,
no issues and `AvailableServiceData`, processing seven work items. This validates
the intended cross-product/existence behavior using stored report content rather
than a successful flow status alone.

The final v6 minimal-output case deliberately filtered a known SharePoint
success out with `Status=Failed`. Independently read files contained exactly
JSON `[]` and the single `RecordId` CSV heading with zero data rows; native
completion reported zero selected runs/verified IDs, IDs-only true and
`AvailableServiceData`. This also verified found-but-filtered semantics without
inventing a missing run or placeholder ID.

The coordinating operator completed scoped cloud cleanup: five task-owned
fixture/driver/suite/verifier flows and the synthetic account were deleted and
verified absent. The intended solution retained exactly one final collector and
two required references; the collector remained enabled. The original source
flow and existing connections were not removed. The dedicated HTTP connection,
approved report folder and private proof reports were retained.

All native live evidence is from **one Public demo tenant**; there is no
second-tenant or GCC native verification. These accepted cases do not remove the
specific Dataverse organic-event, privacy, retention, API or partial-repetition
limitations described here.

### Genuine Dataverse trigger gap

A narrowly filtered, task-owned Dataverse row-change fixture was configured with
the supported `OpenApiConnectionWebhook` / `SubscribeWebhookTrigger` shape.
No organic run was observed from its synthetic account create/update during
these checks. No runtime root cause is established from registration, connection,
publication or background-operation metadata alone. Private callback URLs were
not read/replayed/emulated to manufacture a success.

Dataverse canonical/actual-primary-key extraction has generated-expression
fixtures. In addition, a separate **controlled manual native wrapper** copied the
unmodified v6 projection/record blocks and supplied literal legacy Dataverse
runtime input/SubscribeWebhookTrigger metadata plus the actual primary-key map.
Its intended root results were independently read in the actual Power Automate
engine: the known synthetic account GUID was returned, a distinct canonical/
actual-key conflict yielded `Ambiguous` with no ID, and all-zero canonical/key
sentinels yielded no ID. All three native expectations matched.

That controlled block test is **not organic row-change event delivery**, not
retrieval of a genuine Dataverse-triggered source run, not full collector
Dataverse-history integration and not a production test-input override. It does
not close the no-observed-organic-run gap. Nor does the earlier PowerShell
reader's live Dataverse result close this native gap. Do not describe the native
demo as all-scenarios verified.

Keep test receipts, demo-bound packages, report payloads and private solution
ZIPs outside the public source checkout. When exporting the final task solution,
an authorized operator should include the intended collector and required
references, not temporary drivers, suites, report verifiers, fixture flows or
fixture business records. Native test resources can be removed only by their
owner after exact-resource verification; this offline generator performs no
cleanup or tenant mutation.

Sources:

- [Government service description and standard GCC public Entra identity](https://learn.microsoft.com/en-us/power-automate/us-govt)
- [Exact Flow service audience values by cloud](https://learn.microsoft.com/en-us/power-automate/oauth-authentication#audience-values)
- [Power Automate connector availability, including GCC](https://learn.microsoft.com/en-us/connectors/connector-reference/connector-reference-powerautomate-connectors)
- [Government API/runtime host families](https://learn.microsoft.com/en-us/power-automate/ip-address-configuration#use-the-power-automate-web-portal)
- [Reader's aligned Public/GCC profile and auth-module references](../README.md#standard-gcc-government-community-cloud--moderate)
- [Preauthorized HTTP connector and tenant/scope restrictions](https://learn.microsoft.com/en-us/connectors/webcontents/)
- [SharePoint CreateFile and read-content contracts](https://learn.microsoft.com/en-us/connectors/sharepointonline/)
- [Native workflow limits](https://learn.microsoft.com/en-us/power-automate/limits-and-config)
- [Cloud-flow retention limits](https://learn.microsoft.com/en-us/power-automate/limits-and-config#duration-and-retention-limits)
- [Secure data in flow history](https://learn.microsoft.com/en-us/power-automate/how-tos-use-sensitive-input)
- [Content envelopes and base64](https://learn.microsoft.com/en-us/azure/logic-apps/logic-apps-content-type)
- [Native child-flow requirements and Embedded connections](https://learn.microsoft.com/en-us/power-automate/create-child-flows)
- [Microsoft saved Workflow action with workflowReferenceName and body](https://github.com/microsoft/CopilotStudioSamples/blob/b243a7265db85df6ff608f925167edd048b278f9/infrastructure/manage-paygo/sourcecode/Workflows/PollCostandUnlinkEnvironments-AE89C8E6-2544-F111-BEC7-7C1E520AA4DF.json)
- [Runtime Flow API sources and retention references](../README.md#sources)

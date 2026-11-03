# Premium apps in unmanaged Developer environments

A **read-only, tenant-wide PowerShell inventory** for commercial-cloud tenants. It
reports positively identified premium-capability apps currently in **Developer**
environments where **Managed Environments is disabled**, plus separate review and
coverage reports. It does not download apps, export solutions, migrate anything,
grant permissions, or change the tenant.

## Why this inventory matters

Microsoft's [deprecation announcement][deprecation], checked **November 3, 2026**,
states:

| Phase | Date |
| --- | --- |
| New unmanaged developer environment creation ends | November 15, 2026 |
| Existing unmanaged developer environment suspension starts | December 15, 2026 |
| Deletion of suspended unmanaged developer environments starts | January 15, 2027 |

Managed developer environments, including those created by environment routing,
are unaffected. **All apps, flows, agents, Power Pages developer sites, and data in
affected environments are at risk, not just premium apps.** Before suspension,
retain needed environments by enabling Managed Environments with appropriate
licensing, or move their solutions to another supported environment. This script
only helps inventory apps; it is not a backup or a complete migration checklist.

**Managed Environments is not the same as managed/unmanaged solutions.** The
script uses `properties.environmentType` and `properties.isManaged` from environment
inventory. It never uses an app's or solution's `ismanaged` flag to choose environments.

## Prerequisites and permissions

- **Windows PowerShell 5.1** (`powershell.exe`) or **PowerShell 7.4 or newer** (`pwsh`).
  Native client-secret mode only needs the runtime already required by the engine.
  Native certificate mode needs the platform RSA-PSS certificate APIs and a
  compatible RSA key provider (on Windows PowerShell, .NET Framework 4.6+ with a
  CNG key). **Native modes do not require Az.Accounts or .NET Framework 4.7.2+.**
  Windows PowerShell itself always runs on .NET Framework; this is not a claim
  that it can run without its underlying runtime.
- **Az.Accounts is optional**, used only by `-AuthenticationMode AzAccounts`
  or an invocation without native credentials. That mode requires Az.Accounts
  4.0+ and its supported runtime (.NET Framework 4.7.2+ on Windows PowerShell):

  ```powershell
  Install-Module Az.Accounts -MinimumVersion 4.0 -Scope CurrentUser -Repository PSGallery
  ```

  If using AzAccounts, install it from the engine you will use; Windows PowerShell and PowerShell 7
  have different user module directories. If an older Windows PowerShell session
  cannot reach PSGallery, enable TLS 1.2 for that session before installation:

  ```powershell
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  ```

- Your own **Microsoft Entra tenant GUID** and user account. No tenant, account,
  app registration, client secret, or credentials from this repository are used.
- An active **Global Administrator, Power Platform Administrator, Dynamics 365
  Administrator, or Global Reader** Entra role for [full Inventory visibility][inventory].
  Activate PIM assignments **before** signing in. AI Administrator/Reader and
  environment-only or Power Platform RBAC roles are not sufficient.
- Delegated API access to `https://api.powerplatform.com`, including
  `ResourceQuery.Resources.Read`, `PowerApps.Apps.Read`, and
  `EnvironmentManagement.Environments.Read`, as permitted by the tenant and
  [permission reference][permissions]. Your native application's delegated
  permissions, or the Az delegated client, must be permitted
  by your tenant's consent and Conditional Access policies; an administrator may
  need to arrange consent outside this script. See [Microsoft's authentication
  instructions][authentication], including the Az.Accounts example.
- To supplement model-driven coverage, the same user also needs **Dataverse
  delegated access and permission to read published and unpublished app modules
  in every candidate environment**. Tenant administrator/reader roles do not by
  themselves guarantee Dataverse table access. Inaccessible environments are
  reported as failures; the script never assigns roles or creates application users.
- A private **local** output directory with room for reports and a disk-backed
  journal. Avoid network/synchronized folders without reliable exclusive locks and
  atomic same-directory rename semantics. Output includes owner information;
  protect it using your organization's access and retention policies.
  Windows PowerShell retains .NET Framework's legacy path-length restrictions;
  use a short output path such as `C:\Reports\DeveloperApps` so hashed journal
  subdirectories and filenames also fit within those limits.

The script requires a supported full-visibility role in the token's `wids` claim.
If that claim is absent, it stops rather than guessing that a restricted user has
tenant-wide access. Activate the role, acquire a fresh user sign-in, and rerun.
[Claim emission also depends on the resource application's configuration][claims]:
if a fresh token still omits `wids`, this script cannot establish full visibility
with that token configuration. It does not modify Microsoft applications, query
Microsoft Graph, or create permissions to work around the check.

**Every mode remains delegated.** Client secrets and certificates authenticate
your application during a user authorization-code flow; they do **not** make this
an unattended app-only scan. Microsoft's Inventory API returns HTTP 403 for
service-principal/client-credentials and managed-identity requests. The script
never silently falls back to a canvas-only inventory. No Azure subscription is
required.

## Run

Clone/download the whole solution folder, including **`Inventory.psm1` and
`Authentication.ps1`**. Use a new, empty private output directory.

### Native client secret: no Az.Accounts

In your own Microsoft Entra application registration, configure:

- A **Web** redirect URI exactly matching `http://localhost:8400/` (or your
  `-RedirectUri` value). Do not use a SPA or public mobile/desktop redirect type
  for confidential client-secret/certificate authentication.
- Delegated Power Platform API permissions listed above, and Dynamics CRM /
  Dataverse `user_impersonation`, with appropriate administrator consent.
- Your own client secret, or the public certificate corresponding to your private
  key. Do not create/share credentials through this repository.

The script does not create the registration, grant consent, change roles,
import certificates into a store, or alter operating-system settings. The
loopback listener is temporary, IPv4-only, and does not require an HTTP URL ACL or
administrator elevation. The port must be free.

From the repository root:

```powershell
powershell.exe -NoLogo -NoProfile -File .\DeveloperPremiumAppInventory\Get-UnmanagedDeveloperPremiumApps.ps1 `
    -TenantId 'YOUR-TENANT-GUID' `
    -ClientId 'YOUR-CLIENT-GUID' `
    -AuthenticationMode ClientSecret `
    -OutputDirectory 'C:\Reports\DeveloperApps'

$LASTEXITCODE
```

This prompts for the **application client secret** using `Read-Host -AsSecureString`,
then opens Microsoft's browser sign-in for your user account. Your user password
and MFA are handled by Microsoft, never entered into the script. Alternatively,
from an existing PowerShell session:

```powershell
$secret = Read-Host 'Application client secret' -AsSecureString
.\DeveloperPremiumAppInventory\Get-UnmanagedDeveloperPremiumApps.ps1 `
    -TenantId 'YOUR-TENANT-GUID' -ClientId 'YOUR-CLIENT-GUID' `
    -ClientSecret $secret -OutputDirectory 'C:\Reports\DeveloperApps'
```

Client IDs are public identifiers, not passwords. Secrets are accepted only as
`SecureString` or via the secure prompt; do not put plaintext secrets in command
lines, environment variables, source, transcripts, or configuration files.

### Native certificate: no Az.Accounts

Use an existing certificate with an accessible RSA-PSS-capable private key; its
public certificate must already be registered on your own application:

```powershell
$certificate = Get-Item 'Cert:\CurrentUser\My\YOUR-CERTIFICATE-THUMBPRINT'
.\DeveloperPremiumAppInventory\Get-UnmanagedDeveloperPremiumApps.ps1 `
    -TenantId 'YOUR-TENANT-GUID' -ClientId 'YOUR-CLIENT-GUID' `
    -ClientCertificate $certificate -OutputDirectory 'C:\Reports\DeveloperApps'
```

For a PFX file, obtain the object with `Get-PfxCertificate -FilePath ...`, using its
secure password prompt, and pass it as `-ClientCertificate`. Do not export private
keys. Certificate mode signs short-lived **PS256** assertions with a SHA-256
certificate thumbprint, following [Microsoft's certificate credential contract][certificate-auth].
Non-RSA, expired, inaccessible, or RSA-PSS-incompatible keys fail explicitly.

Both native modes use [authorization code + PKCE][auth-code], cryptographically
random callback state, and `form_post` so authorization codes aren't put in browser
URL history. Tokens and refresh tokens stay in memory; refreshing is tenant- and
audience-bound and cannot change user identity mid-scan. Login times out after
600 seconds (`-LoginTimeoutSeconds`).

### Optional Az.Accounts user sign-in

```powershell
powershell.exe -NoLogo -NoProfile -File .\DeveloperPremiumAppInventory\Get-UnmanagedDeveloperPremiumApps.ps1 `
    -TenantId 'YOUR-TENANT-GUID' -AuthenticationMode AzAccounts `
    -OutputDirectory 'C:\Reports\DeveloperApps'
```

For PowerShell 7, replace `powershell.exe` with `pwsh`. No script changes are
needed between engines. Existing checkpoints remain compatible, including
resuming with the other engine on the same machine and output path.

`Auto` selects `Certificate` when a certificate is supplied, `ClientSecret` when
a client ID/secret is supplied, and otherwise `AzAccounts` for backward
compatibility. Conflicting modes/credentials are rejected. AzAccounts signs you
in with `Connect-AzAccount -Tenant ...`, pins that context, disables context
autosave for this process only, and obtains/refreshes audience-specific user
tokens. MFA and Conditional Access remain in effect in every mode.

To supply an existing user context instead:

```powershell
Connect-AzAccount -Tenant '<your-tenant-guid>' -Environment AzureCloud -SkipContextPopulation

.\DeveloperPremiumAppInventory\Get-UnmanagedDeveloperPremiumApps.ps1 `
    -TenantId '<your-tenant-guid>' `
    -OutputDirectory 'C:\Reports\DeveloperApps' `
    -UseExistingContext
```

On Linux/macOS, substitute a suitable local output directory. This implementation
explicitly supports **commercial cloud only**. It does not silently route GCC,
GCC High, DoD, 21Vianet, or air-gapped tenants to commercial endpoints. Although
Inventory supports some government clouds, their endpoint/auth/resource
availability combinations are outside this script's validated contract.

### Results and exit status

| File | Contents |
| --- | --- |
| `PremiumApps.csv` | Positive premium evidence **and confirmed unmanaged Developer environment** |
| `AllApps.csv` | Deduplicated apps in target environments, plus apps whose environment scope needs review |
| `ReviewApps.csv` | Unknown premium classification, unknown app type, uncertain environment scope, or conflicting metadata |
| `Environments.csv` | Every discovered environment, including excluded and empty environments, with scope decision |
| `Coverage.csv` | Source/environment paging status, committed counts, and changing Inventory totals |
| `Failures.csv` | API/access/paging failures, HTTP status, and actionable error text; no HTTP response bodies or tokens |
| `RunSummary.json` | Counts, status, timestamps, scope limitations, and hashes of the six CSV reports |
| `checkpoint.json`, `.sources` | Tenant/options-bound resume metadata and committed, checksummed page journal |

App rows include app ID/name/type/subtype, owner object ID and names/email when
supplied by the bulk admin API, environment ID/name/type/managed state, premium
classification and evidence, creator ID when supplied, timestamps, source names,
and environment/app-list links. Model-driven apps are organization-owned:
`OwnerStatus=NotApplicable`, not a fabricated owner. No per-app Graph owner lookup
is performed. Missing canvas/code owner metadata is `Unknown`.

The app links open the environment's app list, not an assumed app-specific launch
URL. All CSVs have headers even for empty results. Formula-like text is prefixed
with an apostrophe to make spreadsheet opening safer; quoted commas, quotes, and
newlines are preserved.

| Exit code | Meaning |
| --- | --- |
| `0` | All required sources finished, with no review rows or detected count drift, within the documented API scope |
| `1` | Incomplete/failed discovery, access failure, exhausted retries, invalid paging, corruption, interruption, or another fatal error |
| `2` | Source paging finished, but licensing/environment/type metadata or changing totals needs review |

**Do not interpret an empty `PremiumApps.csv` as "no premium apps" unless coverage
and review results establish that conclusion.** A useful partial premium report
can coexist with exit code 1. `ReportsCurrent=false` means the six CSVs may be
absent or from an earlier attempt; use the journal to resume, not those CSVs as a
completed run.

## Coverage and classification decisions

1. **Tenant-wide discovery:** the [Inventory API][query-api] queries the
   `PowerPlatformResources` table, tenant-bound and sorted by unique resource
   `id`, retaining that ID and following every `skipToken`. It discovers all
   environments and resources under `microsoft.powerapps/`, across regions and
   creators, not just the current user's apps or the default environment.
   Environment metadata is left-joined, not inner-joined, so missing environment
   information cannot silently remove apps.
2. **All currently documented app kinds:** canvas, model-driven, code
   (`byocApp`), vibe (`vibeApp`), managed (`microsoftApp`), and App Builder
   (`appBuilderApp`). Unexpected Power Apps resource types remain explicit review
   rows instead of being called standard or dropped. The word "managed" in an
   app subtype does not exclude it from an unmanaged **environment**.
3. **Bulk licensing evidence:** for each target/uncertain environment, the
   documented [Get AdminApps][admin-apps] endpoint is fully paged. A documented
   `connectionReferences` entry with `apiTier=Premium`,
   `isCustomApiConnection=true`, or `isOnPremiseConnection=true` is positive
   premium-capability evidence. Owner details come from the same bulk response.
   Admin-only apps are retained, but their kind is `UnknownAdminApp` unless
   another source establishes it.
4. **Model-driven coverage:** Inventory [only captures published model-driven
   apps][inventory]. The script also fully pages Dataverse `appmodules` and
   [`RetrieveUnpublishedMultiple()`][unpublished] in every candidate environment,
   using `appmoduleid` to reconcile with Inventory's `properties.appModuleId`.
   Deleted component states are excluded; installed/managed solution apps are
   not excluded. These reads require Dataverse access and can fail independently.
   Model-driven apps are classified as premium Dataverse capability, not as proof
   that a particular user lacks qualifying Dynamics 365 rights.
5. **Code apps:** `byocApp` has a [documented premium-capability requirement][code-apps]
   and is classified accordingly. Vibe, managed, and App Builder subtypes are
   discovered but their licensing is **Unknown** without positive bulk evidence.
6. **No invented premium flag:** the published [Inventory schema][schema] has no
   app-level `isPremium`, `usesPremiumApi`, or `appPlanClassification` field.
   This script does not query invented fields or depend on undocumented legacy
   flags. Connector Inventory is preview, has emission gaps, and is not used as
   a claim that missing connector data means standard.
7. **Unknown is intentional:** standard-only, missing, or empty direct connector
   metadata does **not** prove nonpremium. Microsoft documents that an app's
   [license designation can miss premium connectors in called flows][designation].
   The script does not inspect flow definitions, embedded content, individual
   licenses, historical grandfathering, or effective per-user entitlements.
   Review those apps/dependencies before making a final licensing decision.

This is an inventory of apps **currently located** in the environments, not a
historical record of where an app was originally built. Inventory is eventually
consistent (updates within approximately 15 minutes), and live API paging is not
a transactional snapshot. Changing Inventory totals produce visible drift and
exit code 2; source contradictions also require review. For a refreshed view,
use a new directory after changes settle. No API-based scan can promise to
capture a resource created and deleted between observations.

## Large tenants, throttling, and recovery

- **Bounded memory:** page size is at most 1,000. Pages are normalized and
  committed to disk. A 32-way external merge reconciles app IDs and streams CSV
  output; no tenant-wide app/environment dictionary or array is accumulated.
  At most eight audience tokens are cached. Disk use grows with inventory size;
  reserve several times the report size for journals and merge work files.
  Growing collections use generic lists; fixed-size buffers/JSON page arrays stay
  bounded. No array `+=` accumulation or per-app owner lookup is used.
- **No per-app detail calls:** requests are tenant-wide Inventory pages plus
  bulk Admin Apps, environment detail, and two Dataverse collection scans per
  candidate environment. Owners/connectors are not fetched one app at a time.
- **Serial, tenant-wide pacing:** default delay is 1,000 ms between HTTP attempts,
  including retries. It is adjustable, not a claim that a universal API quota
  permits one request/second. No unbounded parallelism is used.
- **Retries:** 408, 429, network/timeouts, and retryable 5xx use finite retries.
  `Retry-After` seconds and HTTP-date, `x-ms-retry-after-ms`, and `retry-after-ms`
  are honored, taking the longest applicable server delay. Without such headers,
  exponential backoff has a 60-second base cap plus jitter. Server delays are
  **never capped down**. If the delay exceeds the retry time budget, the scan
  stops rather than continuing against another environment to evade it.
  Permanent 4xx/501/505 are not blindly retried; 401 permits one token refresh.
- **Timeouts:** default 120 seconds per attempt, including the response body;
  responses larger than 64 MiB fail explicitly. Reduce page size for unusually
  large app metadata. Networking uses native `Invoke-WebRequest` with
  `-UseBasicParsing`, preventing HTML/script execution. One reused PowerShell
  runspace bounds the entire download's time and size without launching a job or
  process for every page. Inventory replies download to short-lived scratch files,
  are checked before parsing, and are removed even on failure; OAuth replies are
  memory-only. Windows PowerShell enables TLS 1.2 for the request and restores the
  prior process setting; PowerShell 7 keeps its operating-system protocol selection.
- **Paging safeguards:** missing/truncated continuations, repeated/cyclic
  tokens, repeated content pages, unordered/duplicate Inventory resource IDs,
  mismatched counts/tenant IDs, and unsafe continuation destinations fail
  explicitly. GET next links are followed unchanged only on the same HTTPS
  origin and path; bearer tokens are never forwarded to an arbitrary next link.
  Repeated logical app IDs within one bulk source are deduplicated and require
  review rather than silently asserting complete, stable discovery.
- **Crash-safe progress:** each sorted page and its hash-chain metadata are
  durably flushed before atomically updating that source's checkpoint. A page
  interrupted before checkpoint commit is replayed; a committed page is not
  re-appended. Reports are regenerated and deduplicated from committed pages,
  never appended in place. An exclusive file lock prevents concurrent writers
  to the same output directory.

Resume with the **same tenant, output path, and page size**:

```powershell
powershell.exe -NoLogo -NoProfile -File .\DeveloperPremiumAppInventory\Get-UnmanagedDeveloperPremiumApps.ps1 `
    -TenantId 'YOUR-TENANT-GUID' -ClientId 'YOUR-CLIENT-GUID' `
    -AuthenticationMode ClientSecret `
    -OutputDirectory 'C:\Reports\DeveloperApps' `
    -Resume `
    -RequestIntervalMilliseconds 2000 `
    -MaxRetries 8 `
    -RetryBudgetSeconds 1800
```

Retry/pacing/timeout settings can change on resume. Completed sources are reused;
incomplete sources retry from their last committed cursor. Resolve permission or
consent errors first. Journal/cursor checksums, source definitions, tenant/cloud/
path/page-size binding, and report hashes are verified before resuming.
Native modes perform a fresh user sign-in when restarting because refresh tokens
are deliberately not saved. Authentication modes can change without changing
inventory scope; the same tenant/output/page-size constraints still apply.

Do not edit/move the journal or CSVs in place. Copy reports elsewhere for analysis.
An expired server continuation token, corrupt/missing committed page, changed
source contract, or deliberately changed output requires a fresh directory
(or restoring the original intact files); the script never silently resets to
page one and appends duplicates. A resume is **not** a fresh point-in-time scan.
Protect journal files as you protect reports; they contain inventory data and
opaque paging cursors, but never access/refresh tokens or credentials.

## Offline validation

No Pester or other test dependency is required, and no tenant sign-in occurs:

```powershell
powershell.exe -NoLogo -NoProfile -File .\DeveloperPremiumAppInventory\tests\Invoke-Tests.ps1
pwsh -NoLogo -NoProfile -File .\DeveloperPremiumAppInventory\tests\Invoke-Tests.ps1
```

Verified on **Windows PowerShell 5.1.26100.9711 (.NET Framework 4.8)** and
**PowerShell 7.6.9**: **54 checks passed on each engine**, including native
secret/certificate flows, native web cmdlets, and the 100,000-app native-secret
inventory with interruption/resume. No live Microsoft tenant sign-in was performed.

The default test run generates **100,000 synthetic apps across 250 environments**,
using paged JSON responses for Inventory, Admin Apps, environment detail, and
published/unpublished Dataverse collections. It interrupts a page commit, resumes,
and asserts exact IDs with no duplicates/skips: **80,000** target apps, **64,000**
positive premium apps, and **16,000** review apps; the other environments are
managed or non-Developer. The smaller tests cover empty inventories, all known
app kinds, unknown metadata, denied access, tenant/role isolation, throttling
headers, retry limits, token refresh, response-body deadlines, bad paging,
corruption, exclusive locks, and separate-process resume. Native-mode tests
exercise secure secret encoding, certificate assertion signature verification,
PKCE, the local form-post callback, token refresh, native HTTP status/backoff
headers, a trickling response-body deadline, and no Az.Accounts import or token
persistence. JSON conversion,
SHA-256 hashing, atomic replacement, and the bounded merge use APIs compatible
with .NET Framework as well as modern .NET. Test evidence records the engine
version and edition.

To also exercise checkpoint resume in both directions between the installed
engines, pass the other executable explicitly:

```powershell
powershell.exe -NoLogo -NoProfile -File .\DeveloperPremiumAppInventory\tests\Invoke-Tests.ps1 `
    -OtherPowerShellPath (Get-Command pwsh).Source
```

Use `-SkipScale` for a smaller development run. `-OutputDirectory` places synthetic
test evidence elsewhere; `test-results.json` and `scale-evidence.json` retain
the assertions/results, and `-KeepOutput` retains generated test inventories.
Inventories use a separate short, unique temporary directory so deeply nested
repository/session paths do not exceed Windows PowerShell's path limits.
Default generated test output and the solution's `reports` folder are Git-ignored.

**Synthetic/offline scale validation is not a live 100,000-app tenant test.**
Production tenant permissions, consent, service behavior, API changes, and actual
quotas must still be checked in your own tenant. This repository's implementation
does not run against the author's or the operator's tenant during tests.

## Sources

- [Unmanaged developer environment deprecation][deprecation]
- [Power Platform inventory: types, roles, limitations, and consistency][inventory]
- [Inventory query specification][inventory-api] and [REST paging contract][query-api]
- [Inventory schema][schema]
- [Admin Apps bulk properties and pagination][admin-apps]
- [Power Platform API authentication][authentication] and [permissions][permissions]
- [Dataverse appmodule schema][appmodule], [unpublished collection function][unpublished],
  and [OData paging][dataverse-paging]
- [App license designation and called-flow limitation][designation]
- [Code app licensing prerequisites][code-apps]
- [Power Platform licensing FAQ][licensing]

[deprecation]: https://learn.microsoft.com/en-us/power-platform/important-changes-coming#deprecation-of-unmanaged-developer-environments-and-the-power-apps-developer-plan
[inventory]: https://learn.microsoft.com/en-us/power-platform/admin/power-platform-inventory
[inventory-api]: https://learn.microsoft.com/en-us/power-platform/admin/inventory-api
[query-api]: https://learn.microsoft.com/en-us/rest/api/power-platform/resourcequery/resource-query/query-resources
[schema]: https://learn.microsoft.com/en-us/power-platform/admin/inventory-schema
[admin-apps]: https://learn.microsoft.com/en-us/rest/api/power-platform/powerapps/apps/get-admin-apps
[authentication]: https://learn.microsoft.com/en-us/power-platform/admin/programmability-authentication-v2
[permissions]: https://learn.microsoft.com/en-us/power-platform/admin/programmability-permission-reference
[appmodule]: https://learn.microsoft.com/en-us/power-apps/developer/data-platform/webapi/reference/appmodule?view=dataverse-latest
[unpublished]: https://learn.microsoft.com/en-us/power-apps/developer/data-platform/webapi/reference/retrieveunpublishedmultiple?view=dataverse-latest
[dataverse-paging]: https://learn.microsoft.com/en-us/power-apps/developer/data-platform/webapi/query/page-results
[designation]: https://learn.microsoft.com/en-us/power-apps/maker/canvas-apps/license-designation
[code-apps]: https://learn.microsoft.com/en-us/power-apps/developer/code-apps/overview
[licensing]: https://learn.microsoft.com/en-us/power-platform/admin/powerapps-flow-licensing-faq
[claims]: https://learn.microsoft.com/en-us/entra/identity-platform/access-token-claims-reference
[auth-code]: https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow
[certificate-auth]: https://learn.microsoft.com/en-us/entra/identity-platform/certificate-credentials

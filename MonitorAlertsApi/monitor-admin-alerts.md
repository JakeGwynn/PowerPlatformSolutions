# Retrieving Power Platform Admin "Monitor → Alerts" via API

Read the Power Platform Admin Center **Monitor → Alerts** data (triggered alerts + alert rules) with
plain **REST calls** under an **app‑only service principal** (client secret or certificate), and
resolve each alert's resource GUID to a real app / flow / agent name.

> Undocumented, portal‑internal feature — routes and choice codes were reverse‑engineered from
> admin‑center traces across three tenants. Treat as observed behavior; re‑capture from the portal
> if a call starts failing.

## Where the alerts live — and how to find them in any tenant

Monitor → Alerts stores its data in a hidden, system‑provisioned **"Platform" environment**
(`environmentSku = Platform`, template `D365_1stPartyAdminApps`) with its own Dataverse org — **not**
the default or customer environments, and **not** in the normal environments list. Two tables hold
everything: `msdyn_triggeredalerts` (fired instances; `msdyn_triggeredalertid` = the
`/monitoring/alerts/{id}` URL segment) and `msdyn_alertrules` (rule definitions).

You can't guess or look up the org URL — you get it from the BAP **`getOrCreate`** call (step 1),
which returns the Platform env for **whatever tenant your token belongs to** (the `tid` claim; there
is no tenant parameter). So for a tenant you've never seen, just get an app‑only token *in that
tenant* and call `getOrCreate`. The org name is random and per‑tenant, so always resolve it at runtime — never hard-code it. The call is idempotent.

The calls, in order:

1. **Discover** the Platform org — `POST api.bap.microsoft.com/.../getOrCreate`
2. **List triggered alerts** — `GET {platformOrg}/msdyn_triggeredalerts`
3. **List alert rules** — `GET {platformOrg}/msdyn_alertrules`
4. **Decode choice codes** — `GET {platformOrg}/EntityDefinitions(...)`
5. **Resolve resource GUID → name** — Flow / Power Apps admin API, or target‑env Dataverse
6. **Resolve environment name** — `GET api.bap.microsoft.com/.../environments/{id}`

## Setup (one‑time, per tenant)

App‑only client‑credentials (secret or certificate). Two grants:

- **Management‑application registration** — `PUT https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/adminApplications/{appId}?api-version=2020-06-01`
  (empty body, admin token). This alone unlocks BAP `getOrCreate` + the Power Apps / Flow admin APIs.
  The **Power Platform Administrator** directory role is **not** required.
- **Dataverse application user** in the Platform env (and in each target env whose model‑driven apps
  / desktop flows / agents you resolve by name — cloud flows and canvas apps go through the admin
  APIs and don't need one). The Platform env blocks unmanaged customizations (`0x80072042`), so you
  can't create a custom least‑privilege role there — assign a built‑in **managed** role; **System
  Administrator** is verified. Once you have `{platformOrg}` (step 1):
  `POST {platformOrg}/api/data/v9.0/systemusers` with
  `{ "applicationid": "{appId}", "businessunitid@odata.bind": "/businessunits({rootBuId})" }`, then
  `POST .../systemusers({id})/systemuserroles_association/$ref` with
  `{ "@odata.id": ".../roles({roleId})" }`.

## Tokens

One token per audience, straight from the token endpoint (no modules / CLI):

| APIs | Audience / scope |
|---|---|
| BAP (`api.bap.microsoft.com`) + Power Apps admin (`api.powerapps.com`) | `https://service.powerapps.com/` |
| Flow admin (`api.flow.microsoft.com`) | `https://service.flow.microsoft.com/` |
| Dataverse (`{org}.crm.dynamics.com`) | `https://{org}.crm.dynamics.com/` |

```powershell
$scope = 'https://service.powerapps.com/.default'   # <audience>/.default
$tok = (Invoke-RestMethod -Method POST -ContentType 'application/x-www-form-urlencoded' `
  -Uri "https://login.microsoftonline.com/{tenantId}/oauth2/v2.0/token" `
  -Body @{ grant_type='client_credentials'; client_id='{appId}'; client_secret=$secret; scope=$scope }).access_token
```

With a certificate, send a signed `client_assertion` (JWT) instead of `client_secret`. **BAP
gotcha:** `Invoke-RestMethod` / `az rest` drop `?api-version=` on POST/PUT to `api.bap.microsoft.com`
(→ `400 InvalidApiVersion`) — use `Invoke-WebRequest` for step 1. GET reads are fine either way.

## The calls

Dataverse routes are relative to `https://{platformOrg}.crm.dynamics.com/api/data/v9.0/`.

### 1. Discover the Platform environment

```http
POST https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/environments/getOrCreate?api-version=2021-04-01
Authorization: Bearer <service.powerapps.com token>
Content-Type: application/json

{ "properties": { "environmentSku": "Platform", "linkedEnvironmentMetadata": { "templates": ["D365_1stPartyAdminApps"] } } }
```

```powershell
$body = @{ properties = @{ environmentSku='Platform'; linkedEnvironmentMetadata=@{ templates=@('D365_1stPartyAdminApps') } } } | ConvertTo-Json -Depth 10
$resp = Invoke-WebRequest -Method POST -ContentType 'application/json' -Body $body `
  -Uri "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/environments/getOrCreate?api-version=2021-04-01" `
  -Headers @{ Authorization = "Bearer $papToken" }
$platformOrg = ($resp.Content | ConvertFrom-Json).properties.linkedEnvironmentMetadata.instanceUrl.TrimEnd('/')
```

Read: `properties.linkedEnvironmentMetadata.instanceUrl` → `{platformOrg}` (all step 2–4 calls target
it); `name` = the Platform environment id.

### 2. List triggered alerts

```http
GET {platformOrg}/msdyn_triggeredalerts?$filter=(statecode eq 0) and createdon gt {isoUtc}&$orderby=severity desc
Authorization: Bearer <{platformOrg} token>
```

URL‑encode the `$filter`. Read per row: `name`; `severity` / `scope` / `metric` / `resourcetype` /
`resourcesubtype` (choice codes — step 4); `resourceids` (JSON‑string array of
`{EnvironmentId, ResourceId}` — step 5); `_alertruleid_value` (→ rule, step 3);
`msdyn_triggeredalertid`; `createdon` (when the alert **fired**).

> The admin center's Alerts list only shows a **recent window** — the portal query filters
> `createdon` to roughly the **last 2 days**, so older triggered alerts aren't shown there even
> though the rows persist. Widen your time filter to see full history.

### 3. List alert rules

```http
GET {platformOrg}/msdyn_alertrules?$filter=(statecode eq 0 or statecode eq 1)&$orderby=createdon desc&$expand=createdby($select=fullname)
Authorization: Bearer <{platformOrg} token>
```

Read: `msdyn_alertruleid`; `name`; `operator` / `value` (threshold); `createdby.fullname` (the portal
**Alert author** — a triggered alert's own `createdby` is a system user); `recipients` (JSON string).
Join to alerts on `_alertruleid_value`.

### 4. Decode the choice codes

```http
GET {platformOrg}/EntityDefinitions(LogicalName='msdyn_triggeredalert')/Attributes/Microsoft.Dynamics.CRM.PicklistAttributeMetadata?$select=LogicalName&$expand=OptionSet($select=Options),GlobalOptionSet($select=Options)
Authorization: Bearer <{platformOrg} token>
```

Each `value[]` → `LogicalName` + `OptionSet.Options[]` (or `GlobalOptionSet.Options[]`) of `Value` +
`Label.UserLocalizedLabel.Label`. Observed values (decode to confirm; may vary by tenant/version):

| Attribute | Codes |
|---|---|
| `resourcetype` | `200000000` Power Apps · `200000001` Power Automate · `200000003` Copilot Studio |
| `resourcesubtype` | `200000000` canvas app · `200000001` model‑driven app · `200000100` desktop flow · `200000101` cloud flow · `200000300` agent |
| `severity` | `200000000` Low · `200000001` Medium · `200000002` High |

The `resourcesubtype` label routes step 5. Empty `resourceids` (environment‑scoped rules) = nothing
to resolve.

### 5. Resolve the resource id → name

Parse `resourceids`; for each `{EnvironmentId, ResourceId}` pick by `resourcesubtype` (get
`{targetOrg}` from step 6):

| Subtype | Call → field to read |
|---|---|
| Cloud flow | `GET https://api.flow.microsoft.com/providers/Microsoft.ProcessSimple/scopes/admin/environments/{environmentId}/v2/flows/{resourceId}?api-version=2016-11-01` → `properties.displayName` |
| Canvas app | `GET https://api.powerapps.com/providers/Microsoft.PowerApps/scopes/admin/environments/{environmentId}/apps/{resourceId}?api-version=2016-11-01` → `properties.displayName` |
| Model‑driven app | `GET {targetOrg}/appmodules({resourceId})?$select=name` → `name` |
| Desktop flow | `GET {targetOrg}/workflows({resourceId})?$select=name` → `name` |
| Agent | `GET {targetOrg}/bots({resourceId})?$select=name` → `name` |

Admin scope resolves flows/apps even when the SP doesn't own them (the portal's maker call 403s —
which is why the name can show as "‑"). Cloud flows are also `workflows` rows, but can live in
non‑Dataverse envs, so prefer the Flow admin API for them.

### 6. Resolve the environment name

```http
GET https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/{environmentId}?api-version=2021-04-01
Authorization: Bearer <service.powerapps.com token>
```

Read: `properties.displayName` (env name, e.g. "Contoso (default)") and
`properties.linkedEnvironmentMetadata.instanceUrl` → `{targetOrg}` for step 5. Cache per environment.

## Verify script

`Get-PowerPlatformAdminAlerts.ps1` (same folder) runs all six steps and prints a resolved table:

```powershell
.\Get-PowerPlatformAdminAlerts.ps1 -AppId {appId} -TenantId {tenantId} -ClientSecret $secret -IncludeRules
```

`-AppId` / `-TenantId` / `-ClientSecret` do a raw `client_credentials` request per audience (omit to
fall back to an Azure CLI login); `-SinceDays N` widens the window; `-CsvPath <file>` exports.

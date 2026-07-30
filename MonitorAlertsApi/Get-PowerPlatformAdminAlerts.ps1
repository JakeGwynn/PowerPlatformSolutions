<#
.SYNOPSIS
    Retrieve Power Platform "Monitor > Alerts" (triggered alerts + alert rules) via API and
    resolve each alert's target resource GUID to a friendly app / flow / agent name.

.DESCRIPTION
    The Power Platform Admin Center "Monitor > Alerts" feature stores its data in a hidden,
    system-provisioned "Platform" Dataverse environment (environmentSku = Platform, provisioned
    from the D365_1stPartyAdminApps template) - NOT the tenant default or any customer environment,
    and it is not returned by the normal admin environments list. This script:

        1. Discovers that Platform environment's Dataverse URL via the BAP getOrCreate API
           (idempotent - returns the existing environment, does not create a duplicate).
        2. Reads msdyn_triggeredalerts (and optionally msdyn_alertrules) from that org.
        3. Decodes the choice/option-set codes to labels from Dataverse metadata.
        4. Parses each triggered alert's resourceids JSON ({EnvironmentId, ResourceId}) and
           resolves the ResourceId to a display name using the appropriate ADMIN API:
             Cloud flow    -> Power Automate admin API   (works even if you don't own the flow)
             Canvas app    -> Power Apps admin API
             Model app     -> target environment Dataverse  appmodules
             Desktop flow  -> target environment Dataverse  workflows (category 6)
             Agent         -> target environment Dataverse  bots

    NOTE: This is an undocumented, portal-internal feature reverse-engineered from network
    traces. Endpoints and choice codes may change without notice.

.PARAMETER SinceDays
    Only return triggered alerts created within this many days (default 30). The alert's createdon
    is its trigger time. NOTE: the admin center's Alerts list only shows a recent window (roughly the
    last 2 days by createdon), so older triggered alerts are hidden in the portal even though the
    rows persist - widen SinceDays to see history.

.PARAMETER IncludeRules
    Also output the configured alert rules (msdyn_alertrules).

.PARAMETER CsvPath
    Optional path to export the triggered-alert results as CSV.

.PARAMETER AppId
.PARAMETER TenantId
.PARAMETER ClientSecret
    App-only client-credentials. If ClientSecret is supplied, tokens are acquired from the OAuth2
    token endpoint (client_credentials) instead of the Azure CLI - no 'az login' needed.

.PREREQUISITES
    - Auth: pass -AppId/-TenantId/-ClientSecret for app-only client-credentials, OR sign in app-only
      with Azure CLI first (az login --service-principal ... --certificate ...).
    - The service principal needs (verified minimum): a management-application registration, and to
      be a Dataverse application user with a read-capable managed role (System Administrator works)
      in the Platform environment - plus in each target environment whose model apps / desktop flows
      / agents you resolve by name. The Power Platform Administrator directory role is NOT required.

.EXAMPLE
    .\Get-PowerPlatformAdminAlerts.ps1 -SinceDays 7 -IncludeRules -CsvPath .\alerts.csv
#>

[CmdletBinding()]
param(
    [int]    $SinceDays = 30,
    [switch] $IncludeRules,
    [string] $CsvPath,
    # App-only client-credentials (client secret). If omitted, falls back to Azure CLI tokens.
    [string] $AppId,
    [string] $TenantId,
    [string] $ClientSecret
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Auth helpers (app-only service principal + certificate tokens via Azure CLI)
# ---------------------------------------------------------------------------
$script:TokenCache = @{}
function Get-Token {
    param([Parameter(Mandatory)][string] $Resource)
    if ($script:TokenCache.ContainsKey($Resource)) { return $script:TokenCache[$Resource] }
    if ($ClientSecret) {
        # App-only client-credentials: resource 'https://host/' -> scope 'https://host/.default'
        $scope = ($Resource.TrimEnd('/')) + '/.default'
        $body  = @{ grant_type = 'client_credentials'; scope = $scope; client_id = $AppId; client_secret = $ClientSecret }
        try {
            $r = Invoke-RestMethod -Method POST -ContentType 'application/x-www-form-urlencoded' `
                -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body $body
            $tok = $r.access_token
        } catch {
            throw "Client-credentials token request failed for scope '$scope': $($_.Exception.Message)"
        }
    }
    else {
        $tok = az account get-access-token --resource $Resource --query accessToken -o tsv 2>$null
    }
    if (-not $tok) {
        throw "Could not obtain a token for '$Resource'. Supply -AppId/-TenantId/-ClientSecret, or sign in app-only with 'az login --service-principal ...'."
    }
    $script:TokenCache[$Resource] = $tok
    return $tok
}

function Invoke-Api {
    param(
        [string] $Method = 'GET',
        [Parameter(Mandatory)][string] $Uri,
        [Parameter(Mandatory)][string] $Token,
        [object] $Body,
        [switch] $AllowFail
    )
    $headers = @{
        Authorization      = "Bearer $Token"
        Accept             = 'application/json'
        'OData-MaxVersion' = '4.0'
        'OData-Version'    = '4.0'
        Consistency        = 'Strong'   # Dataverse strong read; ignored by BAP/Flow/PowerApps
    }
    # Invoke-WebRequest sends the request as-is; unlike Invoke-RestMethod / az rest it does not
    # drop the ?api-version= query string on the api.bap.microsoft.com POST (-> 400 InvalidApiVersion).
    # -UseBasicParsing keeps this working on Windows PowerShell 5.1 (no IE engine); no-op on PS7.
    $params = @{ Method = $Method; Uri = $Uri; Headers = $headers; UseBasicParsing = $true; ErrorAction = 'Stop' }
    if ($null -ne $Body) {
        $params.Body        = ($Body | ConvertTo-Json -Depth 20)
        $params.ContentType = 'application/json'
    }
    try {
        $resp = Invoke-WebRequest @params
        if ($resp.Content) { return ($resp.Content | ConvertFrom-Json) }
        return $null
    }
    catch {
        if ($AllowFail) { Write-Verbose "Invoke-Api $Method $Uri failed: $($_.Exception.Message)"; return $null }
        throw
    }
}

# Well-known audiences
$PowerAppsRes = 'https://service.powerapps.com/'          # api.bap.microsoft.com + api.powerapps.com
$FlowRes      = 'https://service.flow.microsoft.com/'      # api.flow.microsoft.com
$BapRoot      = 'https://api.bap.microsoft.com'
$ApiVer       = 'api-version=2021-04-01'

# ---------------------------------------------------------------------------
# 1) Discover the hidden "Platform" Dataverse environment that stores the alerts
# ---------------------------------------------------------------------------
Write-Host "Discovering the Platform (admin) Dataverse environment..." -ForegroundColor Cyan
$papToken = Get-Token $PowerAppsRes
$platform = Invoke-Api -Method POST -Token $papToken `
    -Uri "$BapRoot/providers/Microsoft.BusinessAppPlatform/environments/getOrCreate?$ApiVer" `
    -Body @{ properties = @{ environmentSku = 'Platform'; linkedEnvironmentMetadata = @{ templates = @('D365_1stPartyAdminApps') } } }

$platformOrg = $platform.properties.linkedEnvironmentMetadata.instanceUrl.TrimEnd('/')
$platformEnvId = $platform.name
if (-not $platformOrg) { throw "Could not resolve the Platform environment Dataverse URL." }
Write-Host "  Platform env : $($platform.properties.displayName)  ($platformEnvId)" -ForegroundColor DarkGray
Write-Host "  Dataverse    : $platformOrg" -ForegroundColor DarkGray

$dvToken = Get-Token $platformOrg

# ---------------------------------------------------------------------------
# 2) Decode choice (option set) codes -> labels from Dataverse metadata
# ---------------------------------------------------------------------------
function Get-ChoiceMaps {
    param([string] $Org, [string] $Token, [string] $Entity)
    $maps = @{}
    $uri = "$Org/api/data/v9.0/EntityDefinitions(LogicalName='$Entity')/Attributes/Microsoft.Dynamics.CRM.PicklistAttributeMetadata?`$select=LogicalName&`$expand=OptionSet(`$select=Options),GlobalOptionSet(`$select=Options)"
    $resp = Invoke-Api -Uri $uri -Token $Token -AllowFail
    foreach ($attr in $resp.value) {
        $opts = $attr.OptionSet.Options
        if (-not $opts) { $opts = $attr.GlobalOptionSet.Options }
        if (-not $opts) { continue }
        $m = @{}
        foreach ($o in $opts) { $m["$($o.Value)"] = $o.Label.UserLocalizedLabel.Label }
        $maps[$attr.LogicalName] = $m
    }
    return $maps
}
Write-Host "Loading alert choice labels from metadata..." -ForegroundColor Cyan
$choice = Get-ChoiceMaps -Org $platformOrg -Token $dvToken -Entity 'msdyn_triggeredalert'
# Merge in choices defined only on the rule entity (e.g. operator) without overwriting existing.
foreach ($kv in (Get-ChoiceMaps -Org $platformOrg -Token $dvToken -Entity 'msdyn_alertrule').GetEnumerator()) {
    if (-not $choice.ContainsKey($kv.Key)) { $choice[$kv.Key] = $kv.Value }
}
function Decode { param($Field, $Value) if ($null -eq $Value) { return $null } $m = $choice[$Field]; if ($m -and $m.ContainsKey("$Value")) { return $m["$Value"] } return "$Value" }

# ---------------------------------------------------------------------------
# 3) Resource-name resolution helpers
# ---------------------------------------------------------------------------
$script:EnvMeta = @{}   # envId -> @{ DisplayName; Org }
function Get-EnvMeta {
    param([string] $EnvId)
    if ($script:EnvMeta.ContainsKey($EnvId)) { return $script:EnvMeta[$EnvId] }
    $meta = @{ DisplayName = $EnvId; Org = $null }
    $envRec = Invoke-Api -Token (Get-Token $PowerAppsRes) -AllowFail `
        -Uri "$BapRoot/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/$EnvId`?$ApiVer"
    if ($envRec) {
        $meta.DisplayName = $envRec.properties.displayName
        $meta.Org = $envRec.properties.linkedEnvironmentMetadata.instanceUrl
        if ($meta.Org) { $meta.Org = $meta.Org.TrimEnd('/') }
    }
    $script:EnvMeta[$EnvId] = $meta
    return $meta
}

function Resolve-DataverseName {
    param([string] $EnvId, [string] $EntitySet, [string] $Id, [string] $Select = 'name')
    $meta = Get-EnvMeta $EnvId
    if (-not $meta.Org) { return $null }
    $rec = Invoke-Api -Token (Get-Token $meta.Org) -AllowFail `
        -Uri "$($meta.Org)/api/data/v9.0/$EntitySet($Id)?`$select=$Select"
    if ($rec) { return $rec.$Select }
    return $null
}

function Resolve-ResourceName {
    param([string] $EnvId, [string] $ResourceId, [string] $TypeLabel, [string] $SubTypeLabel)
    $t = "$TypeLabel $SubTypeLabel".ToLower()
    try {
        if ($t -match 'cloud flow' -or ($t -match 'power automate' -and $t -notmatch 'desktop')) {
            $r = Invoke-Api -Token (Get-Token $FlowRes) -AllowFail `
                -Uri "https://api.flow.microsoft.com/providers/Microsoft.ProcessSimple/scopes/admin/environments/$EnvId/v2/flows/$ResourceId`?api-version=2016-11-01"
            if ($r) { return $r.properties.displayName }
        }
        elseif ($t -match 'desktop flow') {
            return Resolve-DataverseName -EnvId $EnvId -EntitySet 'workflows' -Id $ResourceId
        }
        elseif ($t -match 'canvas') {
            $r = Invoke-Api -Token (Get-Token $PowerAppsRes) -AllowFail `
                -Uri "https://api.powerapps.com/providers/Microsoft.PowerApps/scopes/admin/environments/$EnvId/apps/$ResourceId`?api-version=2016-11-01"
            if ($r) { return $r.properties.displayName }
        }
        elseif ($t -match 'model') {
            return Resolve-DataverseName -EnvId $EnvId -EntitySet 'appmodules' -Id $ResourceId
        }
        elseif ($t -match 'agent' -or $t -match 'copilot' -or $t -match 'bot') {
            return Resolve-DataverseName -EnvId $EnvId -EntitySet 'bots' -Id $ResourceId
        }
    } catch { }
    return $null
}

# ---------------------------------------------------------------------------
# 4) Read alert rules (to enrich triggered alerts with rule name + author)
# ---------------------------------------------------------------------------
Write-Host "Reading alert rules..." -ForegroundColor Cyan
$ruleMap = @{}
$rulesResp = Invoke-Api -Token $dvToken -AllowFail `
    -Uri "$platformOrg/api/data/v9.0/msdyn_alertrules?`$filter=$([uri]::EscapeDataString('(statecode eq 0 or statecode eq 1)'))&`$orderby=createdon%20desc&`$expand=createdby(`$select=fullname)"
$rules = @()
if ($rulesResp) {
    foreach ($r in $rulesResp.value) {
        $ruleMap[$r.msdyn_alertruleid] = @{ Name = $r.name; Author = $r.createdby.fullname }
        $rules += [pscustomobject]@{
            RuleName     = $r.name
            Author       = $r.createdby.fullname
            ResourceType = Decode 'resourcetype'     $r.resourcetype
            ResourceSub  = Decode 'resourcesubtype'  $r.resourcesubtype
            Metric       = Decode 'metric'           $r.metric
            Severity     = Decode 'severity'         $r.severity
            Scope        = Decode 'scope'            $r.scope
            Operator     = Decode 'operator'         $r.operator
            Threshold    = $r.value
            Notify       = Decode 'notificationtype' $r.notificationtype
            State        = if ($r.statecode -eq 0) { 'Active' } else { 'Inactive' }
            CreatedOn    = $r.createdon
            RuleId       = $r.msdyn_alertruleid
        }
    }
}

# ---------------------------------------------------------------------------
# 5) Read triggered alerts and resolve resources
# ---------------------------------------------------------------------------
Write-Host "Reading triggered alerts (last $SinceDays days) and resolving resources..." -ForegroundColor Cyan
$since  = (Get-Date).ToUniversalTime().AddDays(-$SinceDays).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
$filter = "(statecode eq 0) and createdon gt $since"
$taUri  = "$platformOrg/api/data/v9.0/msdyn_triggeredalerts?`$filter=$([uri]::EscapeDataString($filter))&`$orderby=severity%20desc"
$taResp = Invoke-Api -Token $dvToken -Uri $taUri

$results = foreach ($a in $taResp.value) {
    $typeLabel = Decode 'resourcetype'    $a.resourcetype
    $subLabel  = Decode 'resourcesubtype' $a.resourcesubtype

    $envId = $null; $resId = $null; $envName = $null; $resName = $null
    if ($a.resourceids) {
        try {
            $parsed = $a.resourceids | ConvertFrom-Json
            $names = foreach ($ri in @($parsed)) {
                $envId = $ri.EnvironmentId
                $resId = $ri.ResourceId
                $envName = (Get-EnvMeta $envId).DisplayName
                $rn = Resolve-ResourceName -EnvId $envId -ResourceId $resId -TypeLabel $typeLabel -SubTypeLabel $subLabel
                if (-not $rn) { $rn = "(unresolved) $resId" }
                $rn
            }
            $resName = ($names -join '; ')
        } catch { $resName = $a.resourceids }
    }

    [pscustomobject]@{
        AlertName    = $a.name
        RuleName     = $ruleMap[$a._alertruleid_value].Name
        Author       = $ruleMap[$a._alertruleid_value].Author
        Severity     = Decode 'severity'        $a.severity
        Scope        = Decode 'scope'           $a.scope
        Product      = $typeLabel
        ResourceType = $subLabel
        Metric       = Decode 'metric'          $a.metric
        Value        = $a.value
        Environment  = $envName
        ResourceName = $resName
        ResourceId   = $resId
        Notify       = Decode 'notificationtype' $a.notificationtype
        Triggered    = $a.createdon   # createdon = when the alert fired
        AlertId      = $a.msdyn_triggeredalertid
        DetailUrl    = "https://admin.powerplatform.microsoft.com/monitoring/alerts/$($a.msdyn_triggeredalertid)"
    }
}

# ---------------------------------------------------------------------------
# 6) Output
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== TRIGGERED ALERTS ($($results.Count)) ===" -ForegroundColor Green
$results | Format-Table AlertName, Severity, Triggered, ResourceType, Environment, ResourceName -AutoSize

if ($IncludeRules) {
    Write-Host "=== ALERT RULES ($($rules.Count)) ===" -ForegroundColor Green
    $rules | Format-Table RuleName, Author, ResourceType, Metric, Operator, Threshold, Severity, State -AutoSize
}

if ($CsvPath) {
    $results | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "Exported triggered alerts -> $CsvPath" -ForegroundColor Cyan
}

# Emit objects to the pipeline for further processing
$results

#Requires -Version 5.1

<#
.SYNOPSIS
Generates a portable, stopped native Power Automate flow-history collector.

.DESCRIPTION
Offline generator only. Does not authenticate, install dependencies, deploy,
enable, run or change connections. See README.md for manual input, connection,
security, coverage and native runtime limitations. Public is the default.
Standard GCC (Moderate) generation is best-effort/documentation and offline
fixture validated, not live-tested or platform-certified. No explicit Secure
Inputs/Outputs settings are emitted; run history may expose raw responses,
payloads and signed content links to authorized owners/co-owners.

.PARAMETER TenantId
Explicit tenant of the independently verified Embedded connections.

.PARAMETER Cloud
Public (default) or standard GCC (Moderate). Fixed at generation, not a runtime
tenant/connection switch. Both use public Entra/AzureCloud. GCC High, DoD and
China are not included.

.PARAMETER SharePointSiteUrl
Approved HTTPS export site. The report folder must already exist.

.PARAMETER ReportFolderPath
Site-relative library/folder path. Default /Shared Documents/FlowRunHistory.

.PARAMETER WebContentsConnectionName
Dedicated preauthorized connection with resource https://service.flow.microsoft.com/
and base https://api.flow.microsoft.com for Public. GCC requires resource
https://gov.service.flow.microsoft.us/ and base https://gov.api.flow.microsoft.us.
Use a same-target-tenant Embedded connection, not a PPAPI connection.

.PARAMETER SharePointConnectionName
An independently verified connection authorized for the approved report folder.

.PARAMETER OutputPath
Optional new package file. Existing files are never overwritten.

.PARAMETER UseSolutionEnvironmentVariables
Build-time solution mode. Binds target tenant, report site and report folder to
ordinary solution environment-variable parameters instead of fixed values.
End users import the released solution ZIP; they do not need this generator.

.EXAMPLE
.\New-FlowHistoryCollector.ps1 -Cloud GCC -TenantId $tenant -SharePointSiteUrl 'https://YOUR-TENANT.sharepoint.com/sites/Reports' -OutputPath "$env:TEMP\collector-gcc.json"
#>
[CmdletBinding(DefaultParameterSetName = 'Fixed')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Fixed')][guid]$TenantId,
    [Parameter(Mandatory, ParameterSetName = 'Fixed')][uri]$SharePointSiteUrl,
    [Parameter(Mandatory, ParameterSetName = 'Solution')][switch]$UseSolutionEnvironmentVariables,
    [ValidateSet('Public', 'GCC')][string]$Cloud = 'Public',
    [string]$ReportFolderPath = '/Shared Documents/FlowRunHistory',
    [string]$WebContentsConnectionName = 'REPLACE_WITH_VERIFIED_FLOW_CONNECTION',
    [string]$SharePointConnectionName = 'REPLACE_WITH_VERIFIED_SHAREPOINT_CONNECTION',
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $UseSolutionEnvironmentVariables) {
    if ($TenantId -eq [guid]::Empty) { throw 'TenantId cannot be empty.' }
    if ($SharePointSiteUrl.Scheme -ne 'https' -or $SharePointSiteUrl.Port -ne 443 -or
        $SharePointSiteUrl.UserInfo -or $SharePointSiteUrl.Query -or $SharePointSiteUrl.Fragment) {
        throw 'SharePointSiteUrl must be an explicit HTTPS site without credentials, query, fragment or nonstandard port.'
    }
}
if ($ReportFolderPath -notmatch '^/[^?#\\]+$' -or $ReportFolderPath.Contains("'") -or
    $ReportFolderPath -match '(^|/)\.\.?(/|$)' -or $ReportFolderPath.EndsWith('/')) {
    throw 'ReportFolderPath must be a site-relative library/folder path without traversal or trailing slash.'
}
foreach ($binding in @($WebContentsConnectionName, $SharePointConnectionName)) {
    if ($binding -notmatch '^[A-Za-z0-9_-]+$') { throw 'Connection names must be connection identifiers.' }
}
# Keep endpoint/content families aligned with Get-CloudProfile in the reader.
$cloudProfile = if ($Cloud -eq 'GCC') {
    [pscustomobject]@{
        Name = 'GCC'; AzEnvironment = 'AzureCloud'; Authority = 'https://login.microsoftonline.com'
        ApiBase = 'https://gov.api.flow.microsoft.us'; Audience = 'https://gov.service.flow.microsoft.us/'
        ContentSuffixes = @('logic.azure.us', 'api.gov.powerplatform.microsoft.us',
            'gov.api.flow.microsoft.us', 'blob.core.usgovcloudapi.net')
    }
}
else {
    [pscustomobject]@{
        Name = 'Public'; AzEnvironment = 'AzureCloud'; Authority = 'https://login.microsoftonline.com'
        ApiBase = 'https://api.flow.microsoft.com'; Audience = 'https://service.flow.microsoft.com/'
        ContentSuffixes = @('logic.azure.com', 'api.powerplatform.com', 'flow.microsoft.com', 'blob.core.windows.net')
    }
}
$apiBase = $cloudProfile.ApiBase
$apiHost = ([uri]$apiBase).DnsSafeHost
$configuration = @(
    @{ SchemaName = "fhr_$($cloudProfile.Name)TargetTenantId"; DisplayName = 'Target tenant ID'; Description = 'GUID of the tenant owning the mapped collector connections. This is report context, not a way to retarget OAuth.'; Required = $true; DefaultValue = '' },
    @{ SchemaName = "fhr_$($cloudProfile.Name)ReportSiteUrl"; DisplayName = 'Report SharePoint site URL'; Description = 'Approved HTTPS SharePoint site, without a trailing slash. The mapped connection must have create/read permission.'; Required = $true; DefaultValue = '' },
    @{ SchemaName = "fhr_$($cloudProfile.Name)ReportFolderPath"; DisplayName = 'Report folder path'; Description = 'Existing site-relative library/folder path, starting with slash and without a trailing slash.'; Required = $false; DefaultValue = $ReportFolderPath }
)
foreach ($setting in $configuration) { $setting.ParameterName = "$($setting.DisplayName) ($($setting.SchemaName))" }
$tenantValue = $null; $site = $null; $folderValue = $ReportFolderPath
$folderPrefixExpression = "'$ReportFolderPath/'"
if ($UseSolutionEnvironmentVariables) {
    $tenantValue = "@parameters('$($configuration[0].ParameterName)')"
    $site = "@parameters('$($configuration[1].ParameterName)')"
    $folderValue = "@parameters('$($configuration[2].ParameterName)')"
    $folderPrefixExpression = "concat(parameters('$($configuration[2].ParameterName)'),'/')"
}
else {
    $tenantValue = $TenantId.ToString()
    $site = $SharePointSiteUrl.AbsoluteUri.TrimEnd('/')
}
$emptyObject = "@json('{}')"
$emptyArray = "@json('[]')"
$csvColumns = @('RowType', 'TenantId', 'EnvironmentId', 'FlowId', 'FlowDisplayName', 'RunId',
    'OperationName', 'OperationType', 'RepetitionName', 'Side', 'Status', 'Code', 'Message', 'StartTimeUtc', 'EndTimeUtc',
    'DurationSeconds', 'ClientTrackingId', 'ActionTrackingId', 'RepetitionIndexesJson', 'Availability', 'ContentJson', 'Coverage',
    'RecordSource', 'RecordId', 'Table', 'PrimaryKey', 'SiteUrl', 'ListId', 'UniqueId', 'Evidence')

function Step {
    param($Map, [string]$Name, [string]$Type, $Inputs, $After = $null)
    if ($Name.Length -gt 80) { throw "Action name exceeds 80 characters: $Name" }
    if ($Map.Contains($Name)) { throw "Duplicate action $Name" }
    $runAfter = @{}
    if ($null -eq $After -and $Map.Count -gt 0) { $After = @($Map.Keys)[-1] }
    if ($After) { $runAfter[$After] = @('Succeeded') }
    $action = [ordered]@{ type = $Type; runAfter = $runAfter }
    if ($null -ne $Inputs) { $action.inputs = $Inputs }
    $Map[$Name] = $action
}

function Set-Value {
    param($Map, [string]$Name, [string]$Variable, $Value, $After = $null)
    Step $Map $Name 'SetVariable' @{ name = $Variable; value = $Value } $After
}

function Append-Value {
    param($Map, [string]$Name, [string]$Variable, $Value)
    Step $Map $Name 'AppendToArrayVariable' @{ name = $Variable; value = $Value }
}

function Enqueue {
    param($Map, [string]$Name, $Value)
    Step $Map $Name 'If' $null
    $Map[$Name].expression = @{ less = @("@length(variables('WorkQueue'))", "@variables('MaxWorkItems')") }
    $yes = [ordered]@{}
    Append-Value $yes ($Name + '_append') 'WorkQueue' $Value
    $no = [ordered]@{}
    Set-Value $no ($Name + '_cap') 'QueueCapped' $true
    $Map[$Name].actions = $yes
    $Map[$Name].else = @{ actions = $no }
}

function Issue {
    param($Map, [string]$Name, [string]$State, [string]$Message)
    Append-Value $Map $Name 'Issues' ([ordered]@{
        State = $State; Message = $Message
        FlowId = "@coalesce(variables('CurrentWork')?['FlowId'], '')"
        RunId = "@coalesce(variables('CurrentWork')?['RunId'], '')"
        OperationName = "@coalesce(variables('CurrentWork')?['OperationName'], '')"
        Kind = "@coalesce(variables('CurrentWork')?['Kind'], '')"
    })
}

function Condition {
    param($Map, [string]$Name, [string]$Expression, $Yes, $No = $null)
    Step $Map $Name 'If' $null
    $Map[$Name].expression = @{ equals = @($Expression, $true) }
    $Map[$Name].actions = $Yes
    $Map[$Name].else = @{ actions = $(if ($null -ne $No) { $No } else { [ordered]@{} }) }
}

function Each-Index {
    param($Map, [string]$Name, [string]$Collection, $Actions)
    Step $Map $Name 'Foreach' $null
    $Map[$Name].foreach = "@range(0, length($Collection))"
    $Map[$Name].actions = $Actions
    $Map[$Name].runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }
}

function Csv-Row {
    param([string]$Type, $Fields)
    $row = [ordered]@{}
    foreach ($column in $csvColumns) { $row[$column] = '' }
    $row.RowType = $Type
    $row.TenantId = $tenantValue
    $row.EnvironmentId = "@variables('EnvironmentId')"
    foreach ($key in @('FlowId', 'FlowDisplayName', 'RunId', 'OperationName', 'OperationType', 'RepetitionName')) {
        $row[$key] = "@coalesce(variables('CurrentWork')?['$key'], '')"
    }
    foreach ($key in $Fields.Keys) { $row[$key] = $Fields[$key] }
    return $row
}

function Is-Sensitive {
    param([string]$Expression)
    $terms = @('authorization', 'authentication', 'inputslink', 'outputslink', 'access_token',
        'client_secret', 'client_assertion', 'password', 'cookie', 'api-key', 'apikey',
        'bearer ', 'sig=', 'sig%3d', 'signature=', 'token=', 'token%3d')
    return 'or(' + ((@($terms | ForEach-Object {
        "contains(toLower(string($Expression)), '$_')"
    })) -join ',') + ')'
}

function Guid-Test {
    param([string]$Expression)
    $value = "toLower(string($Expression))"
    $stripped = $value
    foreach ($character in '0123456789abcdef-'.ToCharArray()) { $stripped = "replace($stripped,'$character','')" }
    $checks = @("equals(length($value),36)", "equals(length(replace($value,'-','')),32)", "empty($stripped)",
        "not(equals($value,'00000000-0000-0000-0000-000000000000'))")
    foreach ($position in @(8, 13, 18, 23)) {
        $checks += "equals(substring(concat($value,'000000000000000000000000000000000000'),$position,1),'-')"
    }
    return 'and(' + ($checks -join ',') + ')'
}

function Metadata {
    param([string]$Properties)
    return [ordered]@{
        Status = "@coalesce($Properties`?['status'], '')"
        Code = "@coalesce($Properties`?['code'], '')"
        StartTimeUtc = "@coalesce($Properties`?['startTime'], '')"
        EndTimeUtc = "@coalesce($Properties`?['endTime'], '')"
        DurationSeconds = "@if(or(empty($Properties`?['startTime']),empty($Properties`?['endTime'])),json('null'),div(float(sub(ticks($Properties`?['endTime']),ticks($Properties`?['startTime']))),10000000))"
        ClientTrackingId = "@coalesce($Properties`?['correlation']?['clientTrackingId'], '')"
        ActionTrackingId = "@coalesce($Properties`?['correlation']?['actionTrackingId'], '')"
        RepetitionIndexes = "@coalesce($Properties`?['repetitionIndexes'], json('[]'))"
    }
}

function Run-FilterExpression {
    param([string]$Properties)
    return "@and(or(empty(variables('Statuses')),contains(variables('Statuses'),toLower(coalesce($Properties`?['status'],''))),and(contains(variables('Statuses'),'terminated'),equals(toLower(coalesce($Properties`?['code'],'')),'terminated'))),if(empty(variables('FromUtc')),true,greaterOrEquals(ticks($Properties`?['startTime']),ticks(variables('FromUtc')))),if(empty(variables('ToUtc')),true,less(ticks($Properties`?['startTime']),ticks(variables('ToUtc')))))"
}

$actions = [ordered]@{}
$initial = [ordered]@{
    EnvironmentId = @{ type = 'string'; value = "@if(empty(trim(coalesce(triggerBody()?['EnvironmentId'], ''))), workflow()?['tags']?['environmentName'], trim(triggerBody()?['EnvironmentId']))" }
    Mode = @{ type = 'string'; value = "@coalesce(triggerBody()?['Mode'], 'Summary')" }
    IncludeRecord = @{ type = 'boolean'; value = "@or(equals(coalesce(triggerBody()?['Mode'],'Summary'),'CallingRecordId'), equals(coalesce(triggerBody()?['IncludeCallingRecordId'],false),true))" }
    IdOnly = @{ type = 'boolean'; value = "@coalesce(triggerBody()?['IdOnly'],false)" }
    RecordSource = @{ type = 'string'; value = "@coalesce(triggerBody()?['RecordSource'],'Both')" }
    ExportFormat = @{ type = 'string'; value = "@coalesce(triggerBody()?['ExportFormat'],'Both')" }
    MaxWorkItems = @{ type = 'integer'; value = "@int(coalesce(triggerBody()?['MaxWorkItems'],1000))" }
    MaxRuns = @{ type = 'integer'; value = "@int(coalesce(triggerBody()?['MaxRuns'],100))" }
    SnapshotUtc = @{ type = 'string'; value = '@utcNow()' }
    FromUtc = @{ type = 'string'; value = '' }
    ToUtc = @{ type = 'string'; value = '' }
    WorkQueue = @{ type = 'array'; value = @() }
    WorkIndex = @{ type = 'integer'; value = 0 }
    QueueCapped = @{ type = 'boolean'; value = $false }
    RunsCapped = @{ type = 'boolean'; value = $false }
    CurrentWork = @{ type = 'object'; value = @{} }
    ResponseState = @{ type = 'object'; value = @{} }
    PayloadState = @{ type = 'object'; value = @{} }
    TriggerData = @{ type = 'object'; value = @{} }
    Runs = @{ type = 'array'; value = @() }
    Operations = @{ type = 'array'; value = @() }
    Payloads = @{ type = 'array'; value = @() }
    CallingRecords = @{ type = 'array'; value = @() }
    RecordIds = @{ type = 'array'; value = @() }
    Errors = @{ type = 'array'; value = @() }
    Issues = @{ type = 'array'; value = @() }
    CsvRows = @{ type = 'array'; value = @() }
    Visited = @{ type = 'array'; value = @() }
    SelectedRuns = @{ type = 'array'; value = @() }
    MatchedRunIds = @{ type = 'array'; value = @() }
    FlowIds = @{ type = 'array'; value = "@if(empty(trim(coalesce(triggerBody()?['FlowIds'],''))),json('[]'),split(replace(trim(triggerBody()?['FlowIds']),' ',''),','))" }
    RunIds = @{ type = 'array'; value = "@if(empty(trim(coalesce(triggerBody()?['RunIds'],''))),json('[]'),split(replace(trim(triggerBody()?['RunIds']),' ',''),','))" }
    Statuses = @{ type = 'array'; value = "@if(empty(trim(coalesce(triggerBody()?['Status'],''))),json('[]'),split(toLower(replace(trim(triggerBody()?['Status']),' ','')),','))" }
    ExcludedFlowIds = @{ type = 'array'; value = "@union(createArray(toLower(last(split(workflow()?['name'],'/')))),if(empty(trim(coalesce(triggerBody()?['ExcludedFlowIds'],''))),json('[]'),split(toLower(replace(trim(triggerBody()?['ExcludedFlowIds']),' ','')),',')))" }
    PrimaryKeys = @{ type = 'object'; value = "@json(if(empty(trim(coalesce(triggerBody()?['PrimaryKeyMap'],''))),'{}',triggerBody()?['PrimaryKeyMap']))" }
    Root = @{ type = 'string'; value = '' }
}
foreach ($name in $initial.Keys) {
    Step $actions ('Initialize_' + $name) 'InitializeVariable' @{
        variables = @(@{ name = $name; type = $initial[$name].type; value = $initial[$name].value })
    }
}
if ($UseSolutionEnvironmentVariables) {
    $siteParameter = $site.TrimStart('@')
    $folderParameter = $folderValue.TrimStart('@')
    $validConfiguration = "@and($(Guid-Test $tenantValue.TrimStart('@')),if(empty(trim($siteParameter)),false,and(equals(uriScheme($siteParameter),'https'),equals(uriPort($siteParameter),443),not(contains($siteParameter,'@')),not(contains($siteParameter,'?')),not(contains($siteParameter,'#')),not(endsWith($siteParameter,'/')))),startsWith($folderParameter,'/'),not(endsWith($folderParameter,'/')),not(contains($folderParameter,'..')),not(contains($folderParameter,'?')),not(contains($folderParameter,'#')))"
    $invalidConfiguration = [ordered]@{}
    Step $invalidConfiguration 'Stop_unconfigured_solution' 'Terminate' @{
        runStatus = 'Failed'
        runError = @{
            code = 'ConfigureSolutionEnvironmentVariables'
            message = 'Set the solution Target tenant ID, Report SharePoint site URL and existing Report folder path before turning on/running the collector.'
        }
    }
    Condition $actions 'Validate_solution_configuration' $validConfiguration ([ordered]@{}) $invalidConfiguration
}
Step $actions 'Validate_manual_inputs' 'If' $null
$actions.Validate_manual_inputs.expression = @{ and = @(
    @{ greaterOrEquals = @("@variables('MaxWorkItems')", 1) },
    @{ lessOrEquals = @("@variables('MaxWorkItems')", 5000) },
    @{ greaterOrEquals = @("@variables('MaxRuns')", 1) },
    @{ lessOrEquals = @("@variables('MaxRuns')", 10000) },
    @{ not = @{ equals = @("@variables('EnvironmentId')", '') } },
    @{ equals = @("@contains(createArray('Summary','CallingRecordId','Errors','All'),variables('Mode'))", $true) },
    @{ equals = @("@contains(createArray('Both','CSV','JSON'),variables('ExportFormat'))", $true) },
    @{ equals = @("@contains(createArray('Both','Dataverse','SharePoint'),variables('RecordSource'))", $true) },
    @{ equals = @("@or(not(variables('IdOnly')),equals(variables('Mode'),'CallingRecordId'))", $true) },
    @{ equals = @("@or(not(empty(trim(coalesce(triggerBody()?['FromUtc'],'')))),not(empty(trim(coalesce(triggerBody()?['ToUtc'],'')))),and(greaterOrEquals(int(coalesce(triggerBody()?['LastDays'],7)),1),lessOrEquals(int(coalesce(triggerBody()?['LastDays'],7)),36500)))", $true) },
    @{ equals = @("@or(empty(trim(coalesce(triggerBody()?['FromUtc'],''))),endsWith(toUpper(trim(coalesce(triggerBody()?['FromUtc'],''))),'Z'))", $true) },
    @{ equals = @("@or(empty(trim(coalesce(triggerBody()?['ToUtc'],''))),endsWith(toUpper(trim(coalesce(triggerBody()?['ToUtc'],''))),'Z'))", $true) }
) }
$actions.Validate_manual_inputs.actions = @{}
$actions.Validate_manual_inputs.else = @{ actions = @{
    Stop_invalid_inputs = @{ type = 'Terminate'; inputs = @{ runStatus = 'Failed'; runError = @{
        code = 'InvalidCollectorInputs'; message = 'Verify environment, mode, export/source choices, MaxWorkItems 1-5000, MaxRuns 1-10000. IdOnly requires CallingRecordId mode.'
    } }; runAfter = @{} }
} }
Set-Value $actions 'Set_window_from' 'FromUtc' "@if(or(not(empty(trim(coalesce(triggerBody()?['FromUtc'],'')))),not(empty(trim(coalesce(triggerBody()?['ToUtc'],''))))),trim(coalesce(triggerBody()?['FromUtc'],'')),addDays(variables('SnapshotUtc'),mul(-1,int(coalesce(triggerBody()?['LastDays'],7)))))"
Set-Value $actions 'Set_window_to' 'ToUtc' "@if(or(not(empty(trim(coalesce(triggerBody()?['FromUtc'],'')))),not(empty(trim(coalesce(triggerBody()?['ToUtc'],''))))),trim(coalesce(triggerBody()?['ToUtc'],'')),variables('SnapshotUtc'))"
Step $actions 'Validate_utc_window' 'If' $null
$actions.Validate_utc_window.expression = @{ equals = @("@if(or(empty(variables('FromUtc')),empty(variables('ToUtc'))),true,less(ticks(variables('FromUtc')),ticks(variables('ToUtc'))))", $true) }
$actions.Validate_utc_window.actions = @{}
$actions.Validate_utc_window.else = @{ actions = @{
    Stop_invalid_window = @{ type = 'Terminate'; inputs = @{ runStatus = 'Failed'; runError = @{
        code = 'InvalidUTCWindow'; message = 'FromUtc must precede ToUtc. Explicit boundaries must be valid ISO UTC timestamps ending in Z.'
    } }; runAfter = @{} }
} }
Set-Value $actions 'Set_api_root' 'Root' "@concat('$apiBase/providers/Microsoft.ProcessSimple/',if(equals(coalesce(triggerBody()?['AsAdmin'],false),true),'scopes/admin/',''),'environments/',uriComponent(variables('EnvironmentId')))"
$firstStatus = "first(union(variables('Statuses'),createArray('')))"
$statusLiteral = "if(equals($firstStatus,'failed'),'Failed',if(equals($firstStatus,'succeeded'),'Succeeded',if(equals($firstStatus,'cancelled'),'Cancelled','Running')))"
Step $actions 'Candidate_run_filters' 'Compose' @(
    "@if(empty(variables('FromUtc')),'',concat('startTime ge ',formatDateTime(variables('FromUtc'),'yyyy-MM-ddTHH:mm:ss.fffffffZ')))"
    "@if(empty(variables('ToUtc')),'',concat('startTime lt ',formatDateTime(variables('ToUtc'),'yyyy-MM-ddTHH:mm:ss.fffffffZ')))"
    "@if(and(equals(length(variables('Statuses')),1),contains(createArray('failed','succeeded','cancelled','running'),$firstStatus)),concat('status eq ''',$statusLiteral,''''),'')"
)
Step $actions 'Select_nonempty_run_filters' 'Query' @{
    from = "@outputs('Candidate_run_filters')"; where = "@not(empty(item()))"
}
Step $actions 'Run_filter_text' 'Compose' "@join(body('Select_nonempty_run_filters'),' and ')"
Step $actions 'Run_filter_query' 'Compose' "@if(or(not(empty(variables('RunIds'))),empty(outputs('Run_filter_text'))),'',concat('&`$filter=',uriComponent(outputs('Run_filter_text'))))"
Step $actions 'Resolve_collector_identity' 'OpenApiConnection' @{
    host = @{ apiId = '/providers/Microsoft.PowerApps/apis/shared_webcontents'; connectionName = 'shared_webcontents'; operationId = 'InvokeHttp' }
    parameters = @{
        'request/method' = 'GET'
        'request/url' = "@concat('$apiBase/providers/Microsoft.ProcessSimple/environments/',uriComponent(workflow()?['tags']?['environmentName']),'/flows/',uriComponent(last(split(workflow()?['name'],'/'))),'?api-version=2016-11-01')"
    }
    retryPolicy = @{ type = 'exponential'; count = 4; interval = 'PT5S' }
}
$identityFailure = [ordered]@{}
Step $identityFailure 'Stop_unverified_self_identity' 'Terminate' @{
    runStatus = 'Failed'
    runError = @{
        code = 'CollectorIdentityNotVerified'
        message = 'Cannot verify the collector runtime-to-workflow identity mapping. Discovery/export stopped rather than claiming automatic self-exclusion.'
    }
}
Condition $actions 'Verify_collector_identity' "@and(not(empty(body('Resolve_collector_identity')?['properties']?['workflowEntityId'])),equals(toLower(last(split(coalesce(body('Resolve_collector_identity')?['properties']?['resourceId'],''),'/'))),toLower(last(split(workflow()?['name'],'/')))))" ([ordered]@{}) $identityFailure
Step $actions 'Compose_verified_excluded_ids' 'Compose' "@union(variables('ExcludedFlowIds'),createArray(toLower(last(split(workflow()?['name'],'/'))),toLower(last(split(coalesce(body('Resolve_collector_identity')?['name'],''),'/'))),toLower(body('Resolve_collector_identity')?['properties']?['workflowEntityId']),toLower(last(split(body('Resolve_collector_identity')?['properties']?['resourceId'],'/')))))"
Set-Value $actions 'Set_verified_excluded_ids' 'ExcludedFlowIds' "@outputs('Compose_verified_excluded_ids')"
Append-Value $actions 'Seed_empty_selection_guard' 'WorkQueue' @{ Kind = 'NoOp' }

$explicitFlows = [ordered]@{}
$seedRuns = [ordered]@{}
Enqueue $seedRuns 'Queue_explicit_run' ([ordered]@{
    Kind = 'RunDetail'; FlowId = "@variables('FlowIds')[items('For_each_explicit_flow')]"
    FlowDisplayName = ''; RunId = "@variables('RunIds')[items('For_each_explicit_run')]"
    Uri = "@concat('$apiBase/providers/Microsoft.ProcessSimple/environments/',uriComponent(variables('EnvironmentId')),'/flows/',uriComponent(variables('FlowIds')[items('For_each_explicit_flow')]),'/runs/',uriComponent(variables('RunIds')[items('For_each_explicit_run')]),'?api-version=2016-11-01')"
})
$runSeed = [ordered]@{}
Each-Index $runSeed 'For_each_explicit_run' "variables('RunIds')" $seedRuns
$runPages = [ordered]@{}
Enqueue $runPages 'Queue_explicit_flow_runs' ([ordered]@{
    Kind = 'RunPage'; FlowId = "@variables('FlowIds')[items('For_each_explicit_flow')]"; FlowDisplayName = ''
    Uri = "@concat(variables('Root'),'/flows/',uriComponent(variables('FlowIds')[items('For_each_explicit_flow')]),'/runs?api-version=2016-11-01',outputs('Run_filter_query'))"
})
$chooseRuns = [ordered]@{}
Condition $chooseRuns 'Explicit_runs_or_history' "@greater(length(variables('RunIds')),0)" $runSeed $runPages
Condition $explicitFlows 'Exclude_explicit_collector' "@not(contains(variables('ExcludedFlowIds'),toLower(variables('FlowIds')[items('For_each_explicit_flow')])))" $chooseRuns
$explicitSeed = [ordered]@{}
Each-Index $explicitSeed 'For_each_explicit_flow' "variables('FlowIds')" $explicitFlows
$discovery = [ordered]@{}
Enqueue $discovery 'Queue_flow_discovery' ([ordered]@{
    Kind = 'FlowPage'
    Uri = "@concat(variables('Root'),if(equals(coalesce(triggerBody()?['AsAdmin'],false),true),'/v2',''),'/flows?api-version=2016-11-01&include=includeSolutionCloudFlows',if(equals(coalesce(triggerBody()?['AsAdmin'],false),true),'','&`$filter=search(%27personal%27)'))"
})
$sharedDiscovery = [ordered]@{}
Enqueue $sharedDiscovery 'Queue_shared_discovery' ([ordered]@{
    Kind = 'FlowPage'
    Uri = "@concat(variables('Root'),'/flows?api-version=2016-11-01&include=includeSolutionCloudFlows&`$filter=search(%27team%27)')"
})
Condition $discovery 'Also_discover_shared_flows' "@not(equals(coalesce(triggerBody()?['AsAdmin'],false),true))" $sharedDiscovery
Condition $actions 'Choose_flow_selection' "@greater(length(variables('FlowIds')),0)" $explicitSeed $discovery

$work = [ordered]@{}
Step $work 'Peek_work_item' 'Compose' "@variables('WorkQueue')[variables('WorkIndex')]"
Set-Value $work 'Set_current_work' 'CurrentWork' "@outputs('Peek_work_item')"
Step $work 'Advance_work_index' 'IncrementVariable' @{ name = 'WorkIndex'; value = 1 }
Set-Value $work 'Reset_response_state' 'ResponseState' $emptyObject
Set-Value $work 'Reset_payload_state' 'PayloadState' $emptyObject
Step $work 'Fetch_work' 'Scope' $null
$fetch = [ordered]@{}
$remote = [ordered]@{}
Step $remote 'Read_Flow_API' 'OpenApiConnection' @{
    host = @{ apiId = '/providers/Microsoft.PowerApps/apis/shared_webcontents'; connectionName = 'shared_webcontents'; operationId = 'InvokeHttp' }
    parameters = @{ 'request/method' = 'GET'; 'request/url' = "@variables('CurrentWork')?['Uri']" }
    retryPolicy = @{ type = 'exponential'; count = 4; interval = 'PT5S' }
}
Set-Value $remote 'Store_Flow_response' 'ResponseState' @{
    Success = $true; InlineSummary = $false; StatusCode = "@outputs('Read_Flow_API')?['statusCode']"
}
$rememberUri = [ordered]@{}
Append-Value $rememberUri 'Remember_visited_uri' 'Visited' "@variables('CurrentWork')?['Uri']"
Condition $remote 'Remember_collection_visit' "@contains(createArray('FlowPage','RunPage','ActionPage','Repetitions','RunDetail'),variables('CurrentWork')?['Kind'])" $rememberUri
$blockedRemote = [ordered]@{}
Issue $blockedRemote 'Issue_blocked_api_url' 'BlockedOrRepeatedApiUri' 'Authenticated request rejected: URI must be an unvisited HTTPS Flow API read in the selected environment.'
$remoteGuard = [ordered]@{}
$apiGuard = "@and(equals(uriScheme(variables('CurrentWork')?['Uri']),'https'),equals(toLower(uriHost(variables('CurrentWork')?['Uri'])),'$apiHost'),equals(uriPort(variables('CurrentWork')?['Uri']),443),not(contains(variables('CurrentWork')?['Uri'],'@')),not(contains(variables('CurrentWork')?['Uri'],'#')),or(startsWith(uriPath(variables('CurrentWork')?['Uri']),concat('/providers/Microsoft.ProcessSimple/environments/',uriComponent(variables('EnvironmentId')),'/')),startsWith(uriPath(variables('CurrentWork')?['Uri']),concat('/providers/Microsoft.ProcessSimple/scopes/admin/environments/',uriComponent(variables('EnvironmentId')),'/'))),or(contains(createArray('RunExpansion','Operation','Payload'),variables('CurrentWork')?['Kind']),not(contains(variables('Visited'),variables('CurrentWork')?['Uri']))))"
Condition $remoteGuard 'Guard_authenticated_origin' $apiGuard $remote $blockedRemote
$inlineRun = [ordered]@{}
Set-Value $inlineRun 'Store_inline_run_summary' 'ResponseState' @{
    Success = $true; InlineSummary = $true; StatusCode = 200
}
$summaryChoice = [ordered]@{}
Condition $summaryChoice 'Use_existing_run_summary' "@and(equals(variables('CurrentWork')?['Kind'],'RunDetail'),equals(variables('Mode'),'Summary'),not(variables('IncludeRecord')),contains(variables('CurrentWork'),'RunEnvelope'),equals(coalesce(variables('CurrentWork')?['RunEnvelopeComplete'],false),true))" $inlineRun $remoteGuard
$needsApi = "@and(not(contains(createArray('NoOp','Record'),variables('CurrentWork')?['Kind'])),not(and(equals(variables('CurrentWork')?['Kind'],'RunExpansion'),equals(variables('Mode'),'Summary'),not(variables('IncludeRecord')))))"
Condition $fetch 'Work_needs_authenticated_request' $needsApi $summaryChoice
$work.Fetch_work.actions = $fetch
$captureFailure = [ordered]@{}
Set-Value $captureFailure 'Store_failed_Flow_response' 'ResponseState' @{
    Success = $false; StatusCode = "@coalesce(outputs('Read_Flow_API')?['statusCode'],0)"
}
Condition $work 'Capture_failed_fetch_status' ("@and(" + $needsApi.TrimStart('@') + ",not(equals(coalesce(variables('ResponseState')?['Success'],false),true)))") $captureFailure
$work.Capture_failed_fetch_status.runAfter = @{ Fetch_work = @('Succeeded', 'Failed', 'TimedOut') }
Step $work 'Current_response_body' 'Compose' "@if(equals(coalesce(variables('ResponseState')?['Success'],false),true),if(equals(coalesce(variables('ResponseState')?['InlineSummary'],false),true),variables('CurrentWork')?['RunEnvelope'],body('Read_Flow_API')),json('{}'))"
Step $work 'Select_repetition_metadata' 'Query' @{
    from = "@if(empty(coalesce(variables('CurrentWork')?['RepetitionName'],'')),json('[]'),coalesce(outputs('Current_response_body')?['value'],json('[]')))"
    where = "@equals(item()?['name'],variables('CurrentWork')?['RepetitionName'])"
}
Step $work 'Current_operation_properties' 'Compose' "@if(equals(variables('CurrentWork')?['OperationType'],'Trigger'),coalesce(outputs('Current_response_body')?['properties']?['trigger'],json('{}')),if(empty(coalesce(variables('CurrentWork')?['RepetitionName'],'')),coalesce(outputs('Current_response_body')?['properties'],outputs('Current_response_body')),coalesce(first(union(body('Select_repetition_metadata'),createArray(json('{}'))))?['properties'],first(union(body('Select_repetition_metadata'),createArray(json('{}')))))))"

Step $work 'Process_work' 'Scope' $null
$process = [ordered]@{}
Step $process 'Dispatch_work_kind' 'Switch' $null
$process.Dispatch_work_kind.expression = "@variables('CurrentWork')?['Kind']"
$cases = [ordered]@{}
$cases.NoOp = @{ case = 'NoOp'; actions = @{} }

function Page-Branch {
    param([string]$Kind)
    $branch = [ordered]@{}
    $failed = [ordered]@{}
    Issue $failed ($Kind + '_failed') 'CollectionUnavailable' 'Collection could not be read or was not a value array. Authentication, permissions, API compatibility or retention may limit coverage.'
    $good = [ordered]@{}
    $items = [ordered]@{}
    Step $items ($Kind + '_item') 'Compose' "@outputs('Current_response_body')?['value'][items('For_each_$Kind')]"
    $item = "outputs('$Kind`_item')"
    if ($Kind -eq 'FlowPage') {
        $add = [ordered]@{}
        Enqueue $add 'Queue_discovered_history' @{
            Kind = 'RunPage'; FlowId = "@$item`?['name']"; FlowDisplayName = "@coalesce($item`?['properties']?['displayName'],'')"
            Uri = "@concat(variables('Root'),'/flows/',uriComponent($item`?['name']),'/runs?api-version=2016-11-01',outputs('Run_filter_query'))"
        }
        Condition $items 'Exclude_discovered_collector' "@not(contains(variables('ExcludedFlowIds'),toLower($item`?['name'])))" $add
    }
    elseif ($Kind -eq 'RunPage') {
        $summaryProperties = "$item`?['properties']"
        $summaryMatch = (Run-FilterExpression $summaryProperties).TrimStart('@')
        $summaryIncomplete = "or(empty($summaryProperties`?['status']),and(or(not(empty(variables('FromUtc'))),not(empty(variables('ToUtc')))),empty($summaryProperties`?['startTime'])),and(contains(variables('Statuses'),'terminated'),not(contains(coalesce($summaryProperties,json('{}')),'code'))))"
        $add = [ordered]@{}
        Enqueue $add 'Queue_discovered_run_detail' @{
            Kind = 'RunDetail'; FlowId = "@variables('CurrentWork')?['FlowId']"
            RunEnvelopeComplete = "@not($summaryIncomplete)"
            RunEnvelope = @{
                name = "@$item`?['name']"
                properties = @{
                    status = "@$item`?['properties']?['status']"; code = "@coalesce($item`?['properties']?['code'],'')"
                    startTime = "@$item`?['properties']?['startTime']"; endTime = "@coalesce($item`?['properties']?['endTime'],'')"
                    correlation = @{ clientTrackingId = "@coalesce($item`?['properties']?['correlation']?['clientTrackingId'],'')" }
                }
            }
            FlowDisplayName = "@coalesce(variables('CurrentWork')?['FlowDisplayName'],'')"; RunId = "@$item`?['name']"
            Uri = "@concat('$apiBase/providers/Microsoft.ProcessSimple/environments/',uriComponent(variables('EnvironmentId')),'/flows/',uriComponent(variables('CurrentWork')?['FlowId']),'/runs/',uriComponent($item`?['name']),'?api-version=2016-11-01')"
        }
        $matched = [ordered]@{}
        Append-Value $matched 'Remember_discovered_requested_run' 'MatchedRunIds' "@$item`?['name']"
        Condition $items 'Record_discovered_requested_name' "@and(not(empty(variables('RunIds'))),contains(variables('RunIds'),$item`?['name']))" $matched
        Condition $items 'Select_requested_run_names' "@if(not(empty(variables('RunIds'))),contains(variables('RunIds'),$item`?['name']),if($summaryIncomplete,true,$summaryMatch))" $add
    }
    else {
        Enqueue $items ($Kind + '_queue_operation') @{
            Kind = 'Operation'; FlowId = "@variables('CurrentWork')?['FlowId']"; RunId = "@variables('CurrentWork')?['RunId']"
            FlowDisplayName = "@coalesce(variables('CurrentWork')?['FlowDisplayName'],'')"
            OperationName = $(if ($Kind -eq 'ActionPage') { "@$item`?['name']" } else { "@variables('CurrentWork')?['OperationName']" })
            OperationType = $(if ($Kind -eq 'ActionPage') { 'Action' } else { "@variables('CurrentWork')?['OperationType']" })
            RepetitionName = $(if ($Kind -eq 'ActionPage') { '' } else { "@$item`?['name']" })
            Uri = $(if ($Kind -eq 'ActionPage') {
                "@concat('$apiBase/providers/Microsoft.ProcessSimple/environments/',uriComponent(variables('EnvironmentId')),'/flows/',uriComponent(variables('CurrentWork')?['FlowId']),'/runs/',uriComponent(variables('CurrentWork')?['RunId']),'/actions/',uriComponent($item`?['name']),'?api-version=2016-11-01')"
            } else { "@variables('CurrentWork')?['Uri']" })
        }
    }
    Each-Index $good ('For_each_' + $Kind) "outputs('Current_response_body')?['value']" $items
    $page = [ordered]@{}
    Enqueue $page ($Kind + '_queue_next_page') "@setProperty(variables('CurrentWork'),'Uri',outputs('$Kind`_next_uri'))"
    $next = "coalesce(outputs('Current_response_body')?['nextLink'],outputs('Current_response_body')?['@odata.nextLink'],'')"
    Step $good ($Kind + '_next_uri') 'Compose' "@if(startsWith($next,'/'),concat('$apiBase',$next),if(startsWith($next,'?'),concat('$apiBase',uriPath(variables('CurrentWork')?['Uri']),$next),$next))"
    $nextSafe = "not(or(contains(toLower(outputs('$Kind`_next_uri')),'?sig='),contains(toLower(outputs('$Kind`_next_uri')),'&sig='),contains(toLower(outputs('$Kind`_next_uri')),'?access_token='),contains(toLower(outputs('$Kind`_next_uri')),'&access_token=')))"
    $same = "@and(not(empty(outputs('$Kind`_next_uri'))),equals(uriScheme(outputs('$Kind`_next_uri')),'https'),equals(toLower(uriHost(outputs('$Kind`_next_uri'))),'$apiHost'),equals(uriPort(outputs('$Kind`_next_uri')),443),not(contains(outputs('$Kind`_next_uri'),'@')),not(contains(outputs('$Kind`_next_uri'),'#')),equals(uriPath(outputs('$Kind`_next_uri')),uriPath(variables('CurrentWork')?['Uri'])),$nextSafe)"
    $hasNext = [ordered]@{}
    $badNext = [ordered]@{}
    Issue $badNext ($Kind + '_bad_next') 'PagingLinkRejected' 'Paging link changed collection path. It was not followed.'
    Condition $hasNext ($Kind + '_same_collection') $same $page $badNext
    Condition $good ($Kind + '_has_next') "@not(empty(outputs('$Kind`_next_uri')))" $hasNext
    Condition $branch ($Kind + '_readable') "@and(equals(coalesce(variables('ResponseState')?['Success'],false),true),contains(coalesce(outputs('Current_response_body'),json('{}')),'value'))" $good $failed
    return $branch
}
$cases.FlowPage = @{ case = 'FlowPage'; actions = (Page-Branch 'FlowPage') }
$cases.RunPage = @{ case = 'RunPage'; actions = (Page-Branch 'RunPage') }
$cases.ActionPage = @{ case = 'ActionPage'; actions = (Page-Branch 'ActionPage') }
$cases.Repetitions = @{ case = 'Repetitions'; actions = (Page-Branch 'Repetitions') }

$run = [ordered]@{}
$runGood = [ordered]@{}
Step $runGood 'Current_run_properties' 'Compose' "@coalesce(outputs('Current_response_body')?['properties'],json('{}'))"
Append-Value $runGood 'Remember_matched_run_name' 'MatchedRunIds' "@variables('CurrentWork')?['RunId']"
Step $runGood 'Run_matches_filters' 'Compose' (Run-FilterExpression "outputs('Current_run_properties')")
$takeRun = [ordered]@{}
$accepted = [ordered]@{}
$runRow = Metadata "outputs('Current_run_properties')"
$runRow.TenantId = $tenantValue
$runRow.EnvironmentId = "@variables('EnvironmentId')"
$runRow.FlowId = "@variables('CurrentWork')?['FlowId']"
$runRow.FlowDisplayName = "@coalesce(variables('CurrentWork')?['FlowDisplayName'],'')"
$runRow.RunId = "@variables('CurrentWork')?['RunId']"
Append-Value $accepted 'Add_selected_run' 'Runs' $runRow
Append-Value $accepted 'Remember_selected_run' 'SelectedRuns' "@concat(variables('CurrentWork')?['FlowId'],'/',variables('CurrentWork')?['RunId'])"
Append-Value $accepted 'Run_csv_row' 'CsvRows' (Csv-Row 'Run' @{
    Status = "@coalesce(outputs('Current_run_properties')?['status'],'')"; Code = "@coalesce(outputs('Current_run_properties')?['code'],'')"
    StartTimeUtc = "@coalesce(outputs('Current_run_properties')?['startTime'],'')"; EndTimeUtc = "@coalesce(outputs('Current_run_properties')?['endTime'],'')"
    DurationSeconds = "@if(or(empty(outputs('Current_run_properties')?['startTime']),empty(outputs('Current_run_properties')?['endTime'])),json('null'),div(float(sub(ticks(outputs('Current_run_properties')?['endTime']),ticks(outputs('Current_run_properties')?['startTime']))),10000000))"
    ClientTrackingId = "@coalesce(outputs('Current_run_properties')?['correlation']?['clientTrackingId'],'')"
})
$details = [ordered]@{}
$triggerWork = [ordered]@{}
Enqueue $triggerWork 'Queue_trigger_operation' @{
    Kind = 'Operation'; OperationType = 'Trigger'; FlowId = "@variables('CurrentWork')?['FlowId']"; RunId = "@variables('CurrentWork')?['RunId']"
    FlowDisplayName = "@coalesce(variables('CurrentWork')?['FlowDisplayName'],'')"
    OperationName = "@coalesce(outputs('Current_response_body')?['properties']?['trigger']?['name'],'trigger')"
    RepetitionName = ''; Uri = "@variables('CurrentWork')?['Uri']"
}
Condition $details 'Expand_selected_trigger' "@or(variables('IncludeRecord'),contains(createArray('Errors','All'),variables('Mode')))" $triggerWork
$actionDetail = [ordered]@{}
Enqueue $actionDetail 'Queue_run_actions' @{
    Kind = 'ActionPage'; FlowId = "@variables('CurrentWork')?['FlowId']"; RunId = "@variables('CurrentWork')?['RunId']"
    FlowDisplayName = "@coalesce(variables('CurrentWork')?['FlowDisplayName'],'')"
    Uri = "@concat('$apiBase/providers/Microsoft.ProcessSimple/environments/',uriComponent(variables('EnvironmentId')),'/flows/',uriComponent(variables('CurrentWork')?['FlowId']),'/runs/',uriComponent(variables('CurrentWork')?['RunId']),'/actions?api-version=2016-11-01')"
}
Condition $details 'Need_action_details' "@contains(createArray('Errors','All'),variables('Mode'))" $actionDetail
Enqueue $accepted 'Queue_run_expansion' @{
    Kind = 'RunExpansion'; FlowId = "@variables('CurrentWork')?['FlowId']"; RunId = "@variables('CurrentWork')?['RunId']"
    FlowDisplayName = "@coalesce(variables('CurrentWork')?['FlowDisplayName'],'')"
    Uri = "@variables('CurrentWork')?['Uri']"
}
$runErrors = [ordered]@{}
Append-Value $runErrors 'Run_error_record' 'Errors' @{
    Source = 'Run'; FlowId = "@variables('CurrentWork')?['FlowId']"; RunId = "@variables('CurrentWork')?['RunId']"
    Code = "@coalesce(outputs('Current_run_properties')?['error']?['code'],outputs('Current_run_properties')?['code'],'')"
    Message = "@if($(Is-Sensitive "outputs('Current_run_properties')?['error']"),'[Withheld: credential-bearing error]',string(coalesce(outputs('Current_run_properties')?['error']?['message'],'')))"
}
Condition $accepted 'Need_run_errors' "@and(contains(createArray('Errors','All'),variables('Mode')),or(not(empty(outputs('Current_run_properties')?['error'])),contains(createArray('Failed','Faulted','TimedOut','Aborted','Cancelled','Terminated'),coalesce(outputs('Current_run_properties')?['status'],''))))" $runErrors
$capped = [ordered]@{}
Set-Value $capped 'Mark_run_limit' 'RunsCapped' $true
Condition $takeRun 'Within_run_limit' "@less(length(variables('Runs')),variables('MaxRuns'))" $accepted $capped
Condition $runGood 'Select_run_once' "@and(outputs('Run_matches_filters'),not(contains(variables('SelectedRuns'),concat(variables('CurrentWork')?['FlowId'],'/',variables('CurrentWork')?['RunId']))))" $takeRun
$runBad = [ordered]@{}
$runBadIssue = [ordered]@{}
Issue $runBadIssue 'Run_detail_unavailable' 'RunUnavailable' 'Requested run detail was unavailable; history access does not imply detail access.'
Condition $runBad 'Run_failure_not_cross_flow_404' "@not(and(equals(variables('ResponseState')?['StatusCode'],404),not(empty(variables('RunIds')))))" $runBadIssue
Condition $run 'Run_request_succeeded' "@equals(coalesce(variables('ResponseState')?['Success'],false),true)" $runGood $runBad
$cases.RunDetail = @{ case = 'RunDetail'; actions = $run }
$cases.RunExpansion = @{ case = 'RunExpansion'; actions = $details }

$operation = [ordered]@{}
$props = "outputs('Current_operation_properties')"
$operationMissing = [ordered]@{}
Issue $operationMissing 'Operation_metadata_unavailable' 'OperationMetadataUnavailable' 'Operation metadata could not be resolved from its authenticated selector. No raw metadata or signed links are stored in the work queue.'
Condition $operation 'Operation_metadata_missing' "@or(not(equals(coalesce(variables('ResponseState')?['Success'],false),true)),empty($props))" $operationMissing
$opRow = Metadata $props
$opRow.Availability = "@if(and(equals(coalesce(variables('ResponseState')?['Success'],false),true),not(empty($props))),'Available','Unavailable')"
foreach ($field in @('FlowId', 'FlowDisplayName', 'RunId', 'OperationName', 'OperationType', 'RepetitionName')) {
    $opRow[$field] = "@coalesce(variables('CurrentWork')?['$field'],'')"
}
Append-Value $operation 'Add_operation' 'Operations' $opRow
Append-Value $operation 'Operation_csv_row' 'CsvRows' (Csv-Row "@variables('CurrentWork')?['OperationType']" @{
    Availability = "@if(and(equals(coalesce(variables('ResponseState')?['Success'],false),true),not(empty($props))),'Available','Unavailable')"
    Status = "@coalesce($props`?['status'],'')"; Code = "@coalesce($props`?['code'],'')"
    StartTimeUtc = "@coalesce($props`?['startTime'],'')"; EndTimeUtc = "@coalesce($props`?['endTime'],'')"
    DurationSeconds = "@if(or(empty($props`?['startTime']),empty($props`?['endTime'])),json('null'),div(float(sub(ticks($props`?['endTime']),ticks($props`?['startTime']))),10000000))"
    ClientTrackingId = "@coalesce($props`?['correlation']?['clientTrackingId'],'')"
    ActionTrackingId = "@coalesce($props`?['correlation']?['actionTrackingId'],'')"
    RepetitionIndexesJson = "@string(coalesce($props`?['repetitionIndexes'],json('[]')))"
})
$payloadSides = [ordered]@{}
Step $payloadSides 'Payload_side' 'Compose' "@createArray('inputs','outputs')[items('For_each_payload_side')]"
$queuePayload = [ordered]@{}
Enqueue $queuePayload 'Queue_selected_payload' @{
    Kind = 'Payload'; Side = "@outputs('Payload_side')"
    FlowId = "@variables('CurrentWork')?['FlowId']"; RunId = "@variables('CurrentWork')?['RunId']"
    FlowDisplayName = "@coalesce(variables('CurrentWork')?['FlowDisplayName'],'')"
    OperationName = "@variables('CurrentWork')?['OperationName']"; OperationType = "@variables('CurrentWork')?['OperationType']"
    RepetitionName = "@coalesce(variables('CurrentWork')?['RepetitionName'],'')"
    Uri = "@variables('CurrentWork')?['Uri']"
}
$needSide = "@or(equals(variables('Mode'),'All'),and(variables('IncludeRecord'),equals(variables('CurrentWork')?['OperationType'],'Trigger')),and(equals(variables('Mode'),'Errors'),equals(outputs('Payload_side'),'outputs'),contains(createArray('Failed','Faulted','TimedOut','Aborted','Cancelled','Terminated'),coalesce($props`?['status'],''))))"
Condition $payloadSides 'Need_this_payload_side' $needSide $queuePayload
Each-Index $operation 'For_each_payload_side' "createArray('inputs','outputs')" $payloadSides
$recordTask = [ordered]@{}
Enqueue $recordTask 'Queue_calling_record' @{
    Kind = 'Record'; FlowId = "@variables('CurrentWork')?['FlowId']"; RunId = "@variables('CurrentWork')?['RunId']"
    FlowDisplayName = "@coalesce(variables('CurrentWork')?['FlowDisplayName'],'')"
}
Condition $operation 'Trigger_needs_calling_record' "@and(variables('IncludeRecord'),equals(variables('CurrentWork')?['OperationType'],'Trigger'))" $recordTask
$repeats = [ordered]@{}
$repeatSides = [ordered]@{}
Enqueue $repeatSides 'Queue_operation_repetitions' @{
    Kind = 'Repetitions'
    OperationType = "@createArray('ActionRepetition','ScopeRepetition')[items('For_each_repetition_kind')]"
    FlowId = "@variables('CurrentWork')?['FlowId']"; RunId = "@variables('CurrentWork')?['RunId']"
    FlowDisplayName = "@coalesce(variables('CurrentWork')?['FlowDisplayName'],'')"
    OperationName = "@variables('CurrentWork')?['OperationName']"
    Uri = "@concat('$apiBase/providers/Microsoft.ProcessSimple/environments/',uriComponent(variables('EnvironmentId')),'/flows/',uriComponent(variables('CurrentWork')?['FlowId']),'/runs/',uriComponent(variables('CurrentWork')?['RunId']),'/actions/',uriComponent(variables('CurrentWork')?['OperationName']),'/',createArray('repetitions','scopeRepetitions')[items('For_each_repetition_kind')],'?api-version=2016-11-01')"
}
Each-Index $repeats 'For_each_repetition_kind' "createArray('repetitions','scopeRepetitions')" $repeatSides
Condition $operation 'Action_needs_repetition_probes' "@equals(variables('CurrentWork')?['OperationType'],'Action')" $repeats
$metadataError = [ordered]@{}
Append-Value $metadataError 'Operation_error_record' 'Errors' @{
    Source = "@variables('CurrentWork')?['OperationType']"; FlowId = "@variables('CurrentWork')?['FlowId']"; RunId = "@variables('CurrentWork')?['RunId']"
    OperationName = "@variables('CurrentWork')?['OperationName']"; RepetitionName = "@coalesce(variables('CurrentWork')?['RepetitionName'],'')"
    Code = "@coalesce($props`?['error']?['code'],$props`?['code'],'')"
    Message = "@if($(Is-Sensitive "$props`?['error']"),'[Withheld: credential-bearing error]',string(coalesce($props`?['error']?['message'],'')))"
}
Condition $operation 'Operation_has_error' "@and(contains(createArray('Errors','All'),variables('Mode')),or(not(empty($props`?['error'])),contains(createArray('Failed','Faulted','TimedOut','Aborted','Cancelled','Terminated'),coalesce($props`?['status'],''))))" $metadataError
$retries = [ordered]@{}
Step $retries 'Current_retry_error' 'Compose' "@coalesce($props`?['retryHistory'][items('For_each_retry_error')]?['error']?['error'],$props`?['retryHistory'][items('For_each_retry_error')]?['error'],json('{}'))"
Append-Value $retries 'Add_retry_error_record' 'Errors' @{
    Source = 'Retry'; FlowId = "@variables('CurrentWork')?['FlowId']"; RunId = "@variables('CurrentWork')?['RunId']"
    OperationName = "@variables('CurrentWork')?['OperationName']"; RepetitionName = "@coalesce(variables('CurrentWork')?['RepetitionName'],'')"
    Code = "@coalesce(outputs('Current_retry_error')?['code'],'')"
    Message = "@if($(Is-Sensitive "outputs('Current_retry_error')"),'[Withheld: credential-bearing retry]',string(coalesce(outputs('Current_retry_error')?['message'],'')))"
}
$retryLoop = [ordered]@{}
Each-Index $retryLoop 'For_each_retry_error' "coalesce($props`?['retryHistory'],json('[]'))" $retries
Condition $operation 'Need_retry_errors' "@contains(createArray('Errors','All'),variables('Mode'))" $retryLoop
$cases.Operation = @{ case = 'Operation'; actions = $operation }

$payload = [ordered]@{}
Step $payload 'Payload_link_uri' 'Compose' "@coalesce($props`?[concat(variables('CurrentWork')?['Side'],'Link')]?['uri'],'')"
Step $payload 'Determine_payload_route' 'Compose' "@if(not(equals(coalesce(variables('ResponseState')?['Success'],false),true)),'MetadataUnavailable',if(contains(coalesce($props`?['secureData']?['properties'],json('[]')),variables('CurrentWork')?['Side']),'Secured',if(contains(coalesce($props,json('{}')),variables('CurrentWork')?['Side']),'Inline',if(empty(outputs('Payload_link_uri')),'NotReturned','Download'))))"
Step $payload 'Choose_payload_source' 'Switch' $null
$payload.Choose_payload_source.expression = "@outputs('Determine_payload_route')"
$payloadCases = [ordered]@{}
$inline = [ordered]@{}
Set-Value $inline 'Store_inline_payload' 'PayloadState' @{
    Availability = 'Available'; Reason = 'Inline'
}
$payloadCases.Inline = @{ case = 'Inline'; actions = $inline }
$download = [ordered]@{}
$downloadAllowed = [ordered]@{}
Step $downloadAllowed 'Read_signed_payload_anonymously' 'Http' @{
    method = 'GET'; uri = "@outputs('Payload_link_uri')"
    retryPolicy = @{ type = 'exponential'; count = 4; interval = 'PT5S' }
}
Set-Value $downloadAllowed 'Store_downloaded_payload' 'PayloadState' @{
    Availability = 'Available'; Reason = 'Anonymous HTTPS download; redirect behavior is runtime-controlled.'
}
$blockedContent = [ordered]@{}
Set-Value $blockedContent 'Mark_blocked_content' 'PayloadState' @{
    Availability = 'BlockedHost'; Reason = 'Signed content URI is outside the allowlisted Microsoft runtime/storage origin.'
}
$contentHost = "toLower(uriHost(outputs('Payload_link_uri')))"
$contentPath = "uriPath(outputs('Payload_link_uri'))"
$suffixChecks = @($cloudProfile.ContentSuffixes | ForEach-Object {
    "or(equals($contentHost,'$_'),endsWith($contentHost,'.$($_)'))"
})
if ($cloudProfile.Name -eq 'Public') {
    $suffixChecks += "and(endsWith($contentHost,'.environment.api.powerplatformusercontent.com'),startsWith($contentPath,'/storage/powerautomate/automations/'))"
}
$allowedContent = "@and(equals(uriScheme(outputs('Payload_link_uri')),'https'),equals(uriPort(outputs('Payload_link_uri')),443),not(contains(outputs('Payload_link_uri'),'@')),not(contains(outputs('Payload_link_uri'),'#')),or($($suffixChecks -join ',')))"
Condition $download 'Guard_anonymous_content_origin' $allowedContent $downloadAllowed $blockedContent
$payloadCases.Download = @{ case = 'Download'; actions = $download }
foreach ($state in @('Secured', 'NotReturned', 'MetadataUnavailable')) {
    $missing = [ordered]@{}
    Set-Value $missing ('Mark_payload_' + $state) 'PayloadState' @{
        Availability = $state; Reason = 'Service did not expose this payload; it may be secured, skipped, pending, expired or not applicable.'
    }
    $payloadCases[$state] = @{ case = $state; actions = $missing }
}
$payload.Choose_payload_source.cases = $payloadCases
$payload.Choose_payload_source.default = @{ actions = @{} }
Step $payload 'Finalize_payload' 'Scope' $null
$payload.Finalize_payload.runAfter = @{ Choose_payload_source = @('Succeeded', 'Failed', 'TimedOut') }
$finishPayload = [ordered]@{}
$failedPayload = [ordered]@{}
Set-Value $failedPayload 'Mark_failed_payload_fetch' 'PayloadState' @{
    Availability = 'Unavailable'; Reason = 'Payload download failed (permission, expiry, deletion, throttling or format); no signed URI/error body is exported.'
}
Condition $finishPayload 'Payload_fetch_has_state' "@empty(variables('PayloadState'))" $failedPayload
Step $finishPayload 'Payload_available_for_projection' 'Compose' "@equals(variables('PayloadState')?['Availability'],'Available')"
Step $finishPayload 'Raw_selected_payload' 'Compose' "@if(outputs('Payload_available_for_projection'),if(equals(outputs('Determine_payload_route'),'Inline'),$props`?[variables('CurrentWork')?['Side']],body('Read_signed_payload_anonymously')),json('null'))"
$redactPayload = [ordered]@{}
Set-Value $redactPayload 'Withhold_credential_bearing_payload' 'PayloadState' @{
    Availability = 'WithheldForCredentialSafety'
    Reason = 'Payload contained an authentication/link/signature marker. Entire content is withheld rather than attempting an unsafe partial redaction.'
}
Condition $finishPayload 'Payload_contains_sensitive_marker' "@$(Is-Sensitive "outputs('Raw_selected_payload')")" $redactPayload
Step $finishPayload 'Safe_payload_for_report' 'Compose' "@if(equals(variables('PayloadState')?['Availability'],'Available'),outputs('Raw_selected_payload'),json('null'))"
$unavailable = [ordered]@{}
Issue $unavailable 'Payload_coverage_issue' 'PayloadUnavailableOrWithheld' 'Selected payload unavailable, secured or conservatively withheld. Inspect Payloads.Availability/Reason; no raw signed URI is exported.'
Condition $finishPayload 'Payload_not_available' "@not(equals(variables('PayloadState')?['Availability'],'Available'))" $unavailable
$storeTrigger = [ordered]@{}
Step $storeTrigger 'Private_trigger_object' 'Compose' "@json(if(startsWith(trim(string(outputs('Raw_selected_payload'))),'{'),string(outputs('Raw_selected_payload')),'{}'))"
Step $storeTrigger 'Private_trigger_body' 'Compose' "@coalesce(outputs('Private_trigger_object')?['body'],outputs('Private_trigger_object'))"
Step $storeTrigger 'Private_trigger_table' 'Compose' "@coalesce(outputs('Private_trigger_object')?['parameters']?['subscriptionRequest/entityname'],outputs('Private_trigger_object')?['parameters']?['subscriptionRequest']?['entityname'],outputs('Private_trigger_object')?['parameters']?['entityName'],outputs('Private_trigger_object')?['parameters']?['entityname'],'')"
Step $storeTrigger 'Private_canonical_identity' 'Compose' "@coalesce(outputs('Private_trigger_body')?['@odata.id'],outputs('Private_trigger_body')?['@odata.editLink'],'')"
Step $storeTrigger 'Private_canonical_candidate' 'Compose' "@if(and(endsWith(outputs('Private_canonical_identity'),')'),contains(outputs('Private_canonical_identity'),'(')),first(split(last(split(outputs('Private_canonical_identity'),'(')),')')),'')"
Step $storeTrigger 'Private_actual_key_name' 'Compose' "@coalesce(variables('PrimaryKeys')?[coalesce(variables('TriggerData')?[concat(variables('CurrentWork')?['FlowId'],'/',variables('CurrentWork')?['RunId'])]?['inputs']?['Table'],'')],'')"
Step $storeTrigger 'Private_actual_key_value' 'Compose' "@if(empty(outputs('Private_actual_key_name')),'',coalesce(outputs('Private_trigger_body')?[outputs('Private_actual_key_name')],''))"
Step $storeTrigger 'Safe_trigger_fields' 'Compose' @{
    Availability = "@if(outputs('Payload_available_for_projection'),'Available',variables('PayloadState')?['Availability'])"
    ApiName = "@toLower(last(split(coalesce(outputs('Private_trigger_object')?['host']?['apiId'],''),'/')))"
    OperationId = "@coalesce(outputs('Private_trigger_object')?['host']?['operationId'],'')"
    Table = "@if($(Is-Sensitive "outputs('Private_trigger_table')"),'',outputs('Private_trigger_table'))"
    SiteUrl = "@if($(Is-Sensitive "outputs('Private_trigger_object')?['parameters']?['dataset']"),'[Withheld]',coalesce(outputs('Private_trigger_object')?['parameters']?['dataset'],''))"
    ListId = "@if($(Is-Sensitive "outputs('Private_trigger_object')?['parameters']?['table']"),'[Withheld]',coalesce(outputs('Private_trigger_object')?['parameters']?['table'],''))"
    CanonicalRecordId = "@if($(Guid-Test "outputs('Private_canonical_candidate')"),toLower(outputs('Private_canonical_candidate')),'')"
    ExplicitKeyValue = "@if($(Guid-Test "outputs('Private_actual_key_value')"),toLower(outputs('Private_actual_key_value')),'')"
    ItemId = "@if(isInt(string(coalesce(outputs('Private_trigger_body')?['ID'],''))),if(greater(int(outputs('Private_trigger_body')?['ID']),0),string(outputs('Private_trigger_body')?['ID']),''),'')"
    UniqueId = "@if($(Guid-Test "coalesce(outputs('Private_trigger_body')?['UniqueId'],outputs('Private_trigger_body')?['{UniqueId}'],'')"),coalesce(outputs('Private_trigger_body')?['UniqueId'],outputs('Private_trigger_body')?['{UniqueId}'],''),'')"
}
Step $storeTrigger 'New_trigger_data' 'Compose' "@setProperty(variables('TriggerData'),concat(variables('CurrentWork')?['FlowId'],'/',variables('CurrentWork')?['RunId']),setProperty(coalesce(variables('TriggerData')?[concat(variables('CurrentWork')?['FlowId'],'/',variables('CurrentWork')?['RunId'])],json('{}')),variables('CurrentWork')?['Side'],outputs('Safe_trigger_fields')))"
Set-Value $storeTrigger 'Store_trigger_data' 'TriggerData' "@outputs('New_trigger_data')"
Condition $finishPayload 'Remember_trigger_payload' "@and(variables('IncludeRecord'),equals(variables('CurrentWork')?['OperationType'],'Trigger'))" $storeTrigger
$savePayload = [ordered]@{}
Append-Value $savePayload 'Add_payload_record' 'Payloads' @{
    FlowId = "@variables('CurrentWork')?['FlowId']"; RunId = "@variables('CurrentWork')?['RunId']"
    OperationName = "@variables('CurrentWork')?['OperationName']"; OperationType = "@variables('CurrentWork')?['OperationType']"
    RepetitionName = "@coalesce(variables('CurrentWork')?['RepetitionName'],'')"; Side = "@variables('CurrentWork')?['Side']"
    Availability = "@variables('PayloadState')?['Availability']"; Reason = "@variables('PayloadState')?['Reason']"
    Content = "@outputs('Safe_payload_for_report')"
}
Append-Value $savePayload 'Payload_csv_row' 'CsvRows' (Csv-Row 'Payload' @{
    Side = "@variables('CurrentWork')?['Side']"; Availability = "@variables('PayloadState')?['Availability']"
    ContentJson = "@if(equals(variables('PayloadState')?['Availability'],'Available'),substring(string(createArray(outputs('Safe_payload_for_report'))),1,sub(length(string(createArray(outputs('Safe_payload_for_report')))),2)),'')"
})
Condition $finishPayload 'Export_payload_in_detail_modes' "@contains(createArray('All','Errors'),variables('Mode'))" $savePayload
$specificError = [ordered]@{}
Step $specificError 'Error_payload_object' 'Compose' "@json(if(startsWith(trim(string(outputs('Raw_selected_payload'))),'{'),string(outputs('Raw_selected_payload')),'{}'))"
Step $specificError 'Specific_output_error' 'Compose' "@coalesce(outputs('Error_payload_object')?['body']?['error'],outputs('Error_payload_object')?['error'],json('{}'))"
Step $specificError 'Specific_error_message' 'Compose' "@coalesce(outputs('Specific_output_error')?['message'],outputs('Error_payload_object')?['body']?['message'],outputs('Error_payload_object')?['message'],'')"
Append-Value $specificError 'Add_specific_output_error' 'Errors' @{
    Source = 'PayloadOutput'; FlowId = "@variables('CurrentWork')?['FlowId']"; RunId = "@variables('CurrentWork')?['RunId']"
    OperationName = "@variables('CurrentWork')?['OperationName']"; RepetitionName = "@coalesce(variables('CurrentWork')?['RepetitionName'],'')"
    Code = "@coalesce(outputs('Specific_output_error')?['code'],'')"
    Message = "@if($(Is-Sensitive "outputs('Specific_error_message')"),'[Withheld: credential-bearing error]',string(outputs('Specific_error_message')))"
}
Condition $finishPayload 'Read_failing_output_error' "@and(contains(createArray('All','Errors'),variables('Mode')),equals(variables('CurrentWork')?['Side'],'outputs'),outputs('Payload_available_for_projection'),contains(createArray('Failed','Faulted','TimedOut','Aborted','Cancelled','Terminated'),coalesce($props`?['status'],'')))" $specificError
$payload.Finalize_payload.actions = $finishPayload
$cases.Payload = @{ case = 'Payload'; actions = $payload }

$record = [ordered]@{}
Step $record 'Record_trigger_state' 'Compose' "@coalesce(variables('TriggerData')?[concat(variables('CurrentWork')?['FlowId'],'/',variables('CurrentWork')?['RunId'])],json('{}'))"
Step $record 'Record_input_object' 'Compose' "@coalesce(outputs('Record_trigger_state')?['inputs'],json('{}'))"
Step $record 'Record_output_object' 'Compose' "@coalesce(outputs('Record_trigger_state')?['outputs'],json('{}'))"
Step $record 'Runtime_connector_name' 'Compose' "@toLower(coalesce(outputs('Record_input_object')?['ApiName'],''))"
Step $record 'Runtime_trigger_operation' 'Compose' "@coalesce(outputs('Record_input_object')?['OperationId'],'')"
Step $record 'Runtime_table_name' 'Compose' "@coalesce(outputs('Record_input_object')?['Table'],'')"
Set-Value $record 'Default_unknown_record' 'PayloadState' @{
    Source = 'Unsupported'; RecordId = ''; Availability = 'UnsupportedOrUnavailable'
    Table = "@outputs('Runtime_table_name')"; PrimaryKey = ''; SiteUrl = ''; ListId = ''; UniqueId = ''
    Evidence = 'Runtime trigger inputs only'; Reason = 'Unrecognized connector/trigger or missing runtime payload. No arbitrary GUID/lookup guessing.'
}
Step $record 'Choose_record_connector' 'Switch' $null
$record.Choose_record_connector.expression = "@if(contains(createArray('shared_commondataserviceforapps','commondataserviceforapps','shared_commondataservice','commondataservice'),outputs('Runtime_connector_name')),'dataverse',if(contains(createArray('shared_sharepointonline','sharepointonline'),outputs('Runtime_connector_name')),'shared_sharepointonline',outputs('Runtime_connector_name')))"
$dv = [ordered]@{}
Step $dv 'Canonical_dataverse_uri' 'Compose' "@coalesce(outputs('Record_output_object')?['CanonicalRecordId'],'')"
Step $dv 'Mapped_primary_key' 'Compose' "@coalesce(variables('PrimaryKeys')?[outputs('Runtime_table_name')],'')"
Step $dv 'Dataverse_candidate' 'Compose' "@if(not(empty(outputs('Canonical_dataverse_uri'))),outputs('Canonical_dataverse_uri'),if(empty(outputs('Mapped_primary_key')),'',coalesce(outputs('Record_output_object')?['ExplicitKeyValue'],'')))"
Step $dv 'Dataverse_identity_conflicts' 'Compose' "@and(not(empty(outputs('Canonical_dataverse_uri'))),not(empty(outputs('Mapped_primary_key'))),not(empty(outputs('Record_output_object')?['ExplicitKeyValue'])),not(equals(toLower(string(outputs('Record_output_object')?['ExplicitKeyValue'])),toLower(string(outputs('Dataverse_candidate'))))))"
$dvConflict = [ordered]@{}
Set-Value $dvConflict 'Withhold_conflicting_dataverse_id' 'PayloadState' @{
    Source = 'Dataverse'; RecordId = ''; Availability = 'Ambiguous'; Table = "@outputs('Runtime_table_name')"
    PrimaryKey = "@outputs('Mapped_primary_key')"; Evidence = 'Canonical/actual-key disagreement'
    SiteUrl = ''; ListId = ''; UniqueId = ''; Reason = 'Canonical and mapped actual primary-key identities disagree; neither is guessed.'
}
Condition $dv 'Dataverse_identity_ambiguous' "@outputs('Dataverse_identity_conflicts')" $dvConflict
$dvVerified = [ordered]@{}
Set-Value $dvVerified 'Store_dataverse_identity' 'PayloadState' @{
    Source = 'Dataverse'; RecordId = "@toLower(outputs('Dataverse_candidate'))"; Availability = 'Available'
    Table = "@outputs('Runtime_table_name')"; PrimaryKey = "@outputs('Mapped_primary_key')"
    Evidence = "@if(empty(outputs('Canonical_dataverse_uri')),'ExplicitPrimaryKeyMap','CanonicalODataIdentity')"
    SiteUrl = ''; ListId = ''; UniqueId = ''; Reason = 'Canonical/actual mapped primary key only; no lookup or arbitrary GUID search.'
}
$dvCheck = "@and(contains(createArray('SubscribeWebhookTrigger','SubscribeWebhookTriggerWithOrganization','OnNewItems','OnUpdatedItems','OnDeletedItems'),outputs('Runtime_trigger_operation')),not(equals(variables('RecordSource'),'SharePoint')),not(outputs('Dataverse_identity_conflicts')),$(Guid-Test "outputs('Dataverse_candidate')"))"
Condition $dv 'Verify_dataverse_identity' $dvCheck $dvVerified
$sp = [ordered]@{}
Step $sp 'SharePoint_item_id' 'Compose' "@coalesce(outputs('Record_output_object')?['ItemId'],'')"
$spVerified = [ordered]@{}
Set-Value $spVerified 'Store_sharepoint_identity' 'PayloadState' @{
    Source = 'SharePoint'; RecordId = "@outputs('SharePoint_item_id')"; Availability = 'Available'
    SiteUrl = "@coalesce(outputs('Record_input_object')?['SiteUrl'],'')"
    ListId = "@coalesce(outputs('Record_input_object')?['ListId'],'')"
    UniqueId = "@coalesce(outputs('Record_output_object')?['UniqueId'],'')"
    Table = ''; PrimaryKey = ''; Evidence = 'SharePoint top-level numeric ID'
    Reason = 'Numeric item identity is scoped to site/list; file Identifier and lookup IDs are not used.'
}
Condition $sp 'Verify_sharepoint_identity' "@and(contains(createArray('GetOnNewItems','GetOnUpdatedItems','GetOnChangedItems','GetOnNewFileItems','GetOnUpdatedFileItems','GetOnDeletedItems','GetOnDeletedFileItems'),outputs('Runtime_trigger_operation')),not(equals(variables('RecordSource'),'Dataverse')),if(isInt(outputs('SharePoint_item_id')),greater(int(outputs('SharePoint_item_id')),0),false))" $spVerified
$record.Choose_record_connector.cases = [ordered]@{
    Dataverse = @{ case = 'dataverse'; actions = $dv }
    SharePoint = @{ case = 'shared_sharepointonline'; actions = $sp }
}
$record.Choose_record_connector.default = @{ actions = @{} }
Append-Value $record 'Add_calling_record' 'CallingRecords' @{
    FlowId = "@variables('CurrentWork')?['FlowId']"; RunId = "@variables('CurrentWork')?['RunId']"
    Identity = "@variables('PayloadState')"
}
Append-Value $record 'Calling_record_csv_row' 'CsvRows' (Csv-Row 'CallingRecord' @{
    RecordSource = "@variables('PayloadState')?['Source']"; RecordId = "@variables('PayloadState')?['RecordId']"
    Availability = "@variables('PayloadState')?['Availability']"; Table = "@variables('PayloadState')?['Table']"
    PrimaryKey = "@variables('PayloadState')?['PrimaryKey']"; SiteUrl = "@variables('PayloadState')?['SiteUrl']"
    ListId = "@variables('PayloadState')?['ListId']"; UniqueId = "@variables('PayloadState')?['UniqueId']"
    Evidence = "@variables('PayloadState')?['Evidence']"
})
$recordUnknown = [ordered]@{}
Issue $recordUnknown 'Calling_record_unknown' 'CallingRecordUnknown' 'Runtime trigger identity was unavailable, unsupported or ambiguous. Supply actual Dataverse primary-key map when required; no record ID is invented.'
Condition $record 'Record_identity_unavailable' "@not(equals(variables('PayloadState')?['Availability'],'Available'))" $recordUnknown
$cases.Record = @{ case = 'Record'; actions = $record }
$process.Dispatch_work_kind.cases = $cases
$unknown = [ordered]@{}
Issue $unknown 'Unknown_work_kind' 'UnsupportedWorkItem' 'Unexpected work item kind was not processed.'
$process.Dispatch_work_kind.default = @{ actions = $unknown }
$work.Process_work.actions = $process
Step $work 'Handle_work_failure' 'Scope' $null
$work.Handle_work_failure.runAfter = @{ Process_work = @('Failed', 'TimedOut') }
$failedWork = [ordered]@{}
Issue $failedWork 'Work_processing_failed' 'WorkItemFailed' 'A work item could not be parsed/processed. Its URI, raw response and signed payload are not exported. Coverage is partial.'
$work.Handle_work_failure.actions = $failedWork
Step $work 'Work_iteration_finished' 'Compose' "@variables('WorkIndex')"
$work.Work_iteration_finished.runAfter = @{ Handle_work_failure = @('Succeeded', 'Skipped') }
Step $actions 'Process_bounded_work_queue' 'Until' $null
$actions.Process_bounded_work_queue.expression = "@or(greaterOrEquals(variables('WorkIndex'),length(variables('WorkQueue'))),greaterOrEquals(variables('WorkIndex'),variables('MaxWorkItems')))"
$actions.Process_bounded_work_queue.limit = @{ count = 5000; timeout = 'PT12H' }
$actions.Process_bounded_work_queue.actions = $work

$appendMinimalId = [ordered]@{}
Append-Value $appendMinimalId 'Append_verified_record_id' 'RecordIds' "@string(variables('CallingRecords')[items('For_each_minimal_record')]?['Identity']?['RecordId'])"
$chooseMinimalId = [ordered]@{}
Condition $chooseMinimalId 'Minimal_record_is_verified' "@and(equals(variables('CallingRecords')[items('For_each_minimal_record')]?['Identity']?['Availability'],'Available'),not(empty(variables('CallingRecords')[items('For_each_minimal_record')]?['Identity']?['RecordId'])),not(equals(variables('CallingRecords')[items('For_each_minimal_record')]?['Identity']?['RecordId'],'00000000-0000-0000-0000-000000000000')))" $appendMinimalId
$minimalProjection = [ordered]@{}
Each-Index $minimalProjection 'For_each_minimal_record' "variables('CallingRecords')" $chooseMinimalId
Condition $actions 'Build_minimal_ID_projection' "@variables('IncludeRecord')" $minimalProjection

Step $actions 'Find_missing_requested_runs' 'Query' @{
    from = "@variables('RunIds')"; where = "@not(contains(variables('MatchedRunIds'),item()))"
}
$missingRuns = [ordered]@{}
Issue $missingRuns 'Requested_run_missing' 'RequestedRunNotFound' 'Some selected run names were not found in the accessible/retained selected flows. See Manifest.UnmatchedRunIds.'
Condition $actions 'Selected_runs_unresolved' "@greater(length(body('Find_missing_requested_runs')),0)" $missingRuns
$limitIssue = [ordered]@{}
Issue $limitIssue 'Traversal_limit_reached' 'CollectorLimitReached' 'MaxWorkItems or MaxRuns prevented complete traversal. Pending work and selected-operation payloads may be omitted; increase limits or narrow selection.'
Condition $actions 'Any_collector_cap_reached' "@or(variables('QueueCapped'),variables('RunsCapped'),less(variables('WorkIndex'),length(variables('WorkQueue'))))" $limitIssue
Step $actions 'Compose_report_manifest' 'Compose' ([ordered]@{
    SchemaVersion = '1.0'; TenantId = $tenantValue; Cloud = $cloudProfile.Name
    EnvironmentId = "@variables('EnvironmentId')"; CollectorFlowId = "@workflow()?['name']"; CollectorRunId = "@workflow()?['run']?['name']"
    CollectorWorkflowEntityId = "@body('Resolve_collector_identity')?['properties']?['workflowEntityId']"
    CollectorResourceId = "@body('Resolve_collector_identity')?['properties']?['resourceId']"
    Mode = "@variables('Mode')"; CallingRecordRequested = "@variables('IncludeRecord')"
    IdOnly = "@variables('IdOnly')"; VerifiedRecordIdCount = "@length(variables('RecordIds'))"
    FromUtc = "@variables('FromUtc')"; ToUtc = "@variables('ToUtc')"; SnapshotUtc = "@variables('SnapshotUtc')"
    Coverage = "@if(empty(variables('Issues')),'AvailableServiceData','Partial')"
    QueuedWorkItems = "@length(variables('WorkQueue'))"; ProcessedWorkItems = "@variables('WorkIndex')"
    MaxWorkItems = "@variables('MaxWorkItems')"; MaxRuns = "@variables('MaxRuns')"
    QueueCapped = "@variables('QueueCapped')"; RunsCapped = "@variables('RunsCapped')"
    SelectedRunCount = "@length(variables('Runs'))"; UnmatchedRunIds = "@body('Find_missing_requested_runs')"
    ExcludedFlowIds = "@variables('ExcludedFlowIds')"
    RunHistoryLimitation = 'No explicit Secure Inputs/Outputs settings are applied. Raw responses, payloads and signed links may be visible to authorized collector owners/co-owners in run history. Protect collector access or add supported settings yourself; OAuth and report withholding remain enabled.'
    Limits = @('Service retention/permissions/secure data apply.', 'Only the runtime action collection is used for action discovery.',
        'Scalar/unsupported repetition routes are explicit coverage issues.', 'No Dataverse metadata connector: canonical IDs or explicit actual-key map only.',
        'Credential/link-marker payloads are conservatively withheld in full.', 'HTTP redirect behavior is runtime-controlled; no blocked-redirect claim.',
        'Secure Inputs/Outputs is not applied; raw responses, payloads and signed links may be visible to authorized collector owners/co-owners.',
        'SharePoint create uses unique run/GUID names, not an atomic create-if-absent guarantee.')
})
Step $actions 'Compose_structured_report' 'Compose' ([ordered]@{
    Manifest = "@outputs('Compose_report_manifest')"; Runs = "@variables('Runs')"; Operations = "@variables('Operations')"
    Payloads = "@variables('Payloads')"; CallingRecords = "@variables('CallingRecords')"; Errors = "@variables('Errors')"; Issues = "@variables('Issues')"
})
Step $actions 'Compose_unique_report_prefix' 'Compose' "@concat('flow-history-',workflow()?['run']?['name'],'-',guid())"
$errorRows = [ordered]@{}
Append-Value $errorRows 'Add_error_csv_row' 'CsvRows' (Csv-Row 'Error' @{
    FlowId = "@coalesce(variables('Errors')[items('For_each_exported_error')]?['FlowId'],'')"
    FlowDisplayName = ''
    RunId = "@coalesce(variables('Errors')[items('For_each_exported_error')]?['RunId'],'')"
    OperationName = "@coalesce(variables('Errors')[items('For_each_exported_error')]?['OperationName'],'')"
    RepetitionName = "@coalesce(variables('Errors')[items('For_each_exported_error')]?['RepetitionName'],'')"
    Code = "@coalesce(variables('Errors')[items('For_each_exported_error')]?['Code'],'')"
    Message = "@coalesce(variables('Errors')[items('For_each_exported_error')]?['Message'],'')"
})
Each-Index $actions 'For_each_exported_error' "variables('Errors')" $errorRows
$issueRows = [ordered]@{}
Append-Value $issueRows 'Add_issue_csv_row' 'CsvRows' (Csv-Row 'CoverageIssue' @{
    FlowId = "@coalesce(variables('Issues')[items('For_each_exported_issue')]?['FlowId'],'')"
    FlowDisplayName = ''
    RunId = "@coalesce(variables('Issues')[items('For_each_exported_issue')]?['RunId'],'')"
    OperationName = "@coalesce(variables('Issues')[items('For_each_exported_issue')]?['OperationName'],'')"
    Availability = "@coalesce(variables('Issues')[items('For_each_exported_issue')]?['State'],'')"
    Message = "@coalesce(variables('Issues')[items('For_each_exported_issue')]?['Message'],'')"
})
Each-Index $actions 'For_each_exported_issue' "variables('Issues')" $issueRows
$csv = [ordered]@{}
$normalCsv = [ordered]@{}
Step $normalCsv 'Create_CSV_table' 'Table' @{
    from = "@variables('CsvRows')"; format = 'CSV'
    columns = @($csvColumns | ForEach-Object {
        $value = "@item()?['$_']"
        if ($_ -eq 'Coverage') { $value = "@outputs('Compose_report_manifest')?['Coverage']" }
        @{ header = $_; value = $value }
    })
}
$minimalCsv = [ordered]@{}
Step $minimalCsv 'Select_minimal_CSV_rows' 'Select' @{
    from = "@variables('RecordIds')"; select = @{ RecordId = '@item()' }
}
Step $minimalCsv 'Create_minimal_CSV_table' 'Table' @{
    from = "@body('Select_minimal_CSV_rows')"; format = 'CSV'
    columns = @(@{ header = 'RecordId'; value = "@item()?['RecordId']" })
}
Condition $csv 'Choose_CSV_projection' "@variables('IdOnly')" $minimalCsv $normalCsv
Step $csv 'CSV_export_text' 'Compose' "@if(variables('IdOnly'),body('Create_minimal_CSV_table'),body('Create_CSV_table'))"
Step $csv 'Write_CSV_report' 'OpenApiConnection' @{
    host = @{ apiId = '/providers/Microsoft.PowerApps/apis/shared_sharepointonline'; connectionName = 'shared_sharepointonline'; operationId = 'CreateFile' }
    parameters = @{
        dataset = $site; folderPath = $folderValue
        name = "@concat(outputs('Compose_unique_report_prefix'),'.csv')"; body = "@outputs('CSV_export_text')"
    }
}
Step $csv 'Read_CSV_report_back' 'OpenApiConnection' @{
    host = @{ apiId = '/providers/Microsoft.PowerApps/apis/shared_sharepointonline'; connectionName = 'shared_sharepointonline'; operationId = 'GetFileContentByPath' }
    parameters = @{
        dataset = $site; path = "@concat($folderPrefixExpression,outputs('Compose_unique_report_prefix'),'.csv')"; inferContentType = $false
    }
}
$csvMismatch = [ordered]@{}
Step $csvMismatch 'Stop_CSV_readback_mismatch' 'Terminate' @{
    runStatus = 'Failed'; runError = @{ code = 'CSVReadBackMismatch'; message = 'Created report bytes did not match the expected CSV. Do not treat the export as verified.' }
}
Condition $csv 'CSV_bytes_match' "@not(equals(body('Read_CSV_report_back')?['`$content'],base64(outputs('CSV_export_text'))))" $csvMismatch
Condition $actions 'Export_CSV_requested' "@contains(createArray('Both','CSV'),variables('ExportFormat'))" $csv
$json = [ordered]@{}
Step $json 'JSON_export_text' 'Compose' "@if(variables('IdOnly'),string(variables('RecordIds')),string(outputs('Compose_structured_report')))"
Step $json 'Write_JSON_report' 'OpenApiConnection' @{
    host = @{ apiId = '/providers/Microsoft.PowerApps/apis/shared_sharepointonline'; connectionName = 'shared_sharepointonline'; operationId = 'CreateFile' }
    parameters = @{
        dataset = $site; folderPath = $folderValue
        name = "@concat(outputs('Compose_unique_report_prefix'),'.json')"; body = "@outputs('JSON_export_text')"
    }
}
Step $json 'Read_JSON_report_back' 'OpenApiConnection' @{
    host = @{ apiId = '/providers/Microsoft.PowerApps/apis/shared_sharepointonline'; connectionName = 'shared_sharepointonline'; operationId = 'GetFileContentByPath' }
    parameters = @{
        dataset = $site; path = "@concat($folderPrefixExpression,outputs('Compose_unique_report_prefix'),'.json')"; inferContentType = $false
    }
}
$jsonMismatch = [ordered]@{}
Step $jsonMismatch 'Stop_JSON_readback_mismatch' 'Terminate' @{
    runStatus = 'Failed'; runError = @{ code = 'JSONReadBackMismatch'; message = 'Created report bytes did not match expected structured JSON. Do not treat the export as verified.' }
}
Condition $json 'JSON_bytes_match' "@not(equals(body('Read_JSON_report_back')?['`$content'],base64(outputs('JSON_export_text'))))" $jsonMismatch
Condition $actions 'Export_JSON_requested' "@contains(createArray('Both','JSON'),variables('ExportFormat'))" $json
Step $actions 'Compose_completion_receipt' 'Compose' @{
    Manifest = "@outputs('Compose_report_manifest')"; ReportSite = $site; ReportFolder = $folderValue
    ReportPrefix = "@outputs('Compose_unique_report_prefix')"; ExportFormat = "@variables('ExportFormat')"
}
Step $actions 'Respond_to_parent' 'Response' @{
    statusCode = 200
    body = @{
        collectorrunid = "@workflow()?['run']?['name']"
        collectorruntimeid = "@workflow()?['name']"
        reportsite = $site
        reportfolder = $folderValue
        reportprefix = "@outputs('Compose_unique_report_prefix')"
        mode = "@variables('Mode')"
        coverage = "@if(empty(variables('Issues')),'AvailableServiceData','Partial')"
        selectedruncount = "@string(length(variables('Runs')))"
        idonly = "@string(variables('IdOnly'))"
        recordidcount = "@string(length(variables('RecordIds')))"
    }
    schema = @{
        type = 'object'
        properties = @{
            collectorrunid = @{ type = 'string'; title = 'Collector run ID'; 'x-ms-content-hint' = 'TEXT' }
            collectorruntimeid = @{ type = 'string'; title = 'Collector runtime ID'; 'x-ms-content-hint' = 'TEXT' }
            reportsite = @{ type = 'string'; title = 'Report site'; 'x-ms-content-hint' = 'TEXT' }
            reportfolder = @{ type = 'string'; title = 'Report folder'; 'x-ms-content-hint' = 'TEXT' }
            reportprefix = @{ type = 'string'; title = 'Report filename prefix'; 'x-ms-content-hint' = 'TEXT' }
            mode = @{ type = 'string'; title = 'Requested mode'; 'x-ms-content-hint' = 'TEXT' }
            coverage = @{ type = 'string'; title = 'Coverage'; 'x-ms-content-hint' = 'TEXT' }
            selectedruncount = @{ type = 'string'; title = 'Selected run count'; 'x-ms-content-hint' = 'TEXT' }
            idonly = @{ type = 'string'; title = 'IDs-only export'; 'x-ms-content-hint' = 'TEXT' }
            recordidcount = @{ type = 'string'; title = 'Verified record ID count'; 'x-ms-content-hint' = 'TEXT' }
        }
    }
}
$actions.Respond_to_parent.kind = 'PowerApp'

$properties = [ordered]@{
    EnvironmentId = @{ type = 'string'; title = 'Environment ID (blank = this environment)' }
    FlowIds = @{ type = 'string'; title = 'Flow IDs, comma separated (blank = discover all visible)' }
    RunIds = @{ type = 'string'; title = 'Run names, comma separated (optional)' }
    Status = @{ type = 'string'; title = 'Run statuses, comma separated (optional)' }
    Mode = @{ type = 'string'; title = 'Mode'; enum = @('Summary', 'CallingRecordId', 'Errors', 'All'); default = 'Summary' }
    IncludeCallingRecordId = @{ type = 'boolean'; title = 'Include calling record ID with Errors/All'; default = $false }
    IdOnly = @{ type = 'boolean'; title = 'Record ID strings only (CallingRecordId mode)'; default = $false }
    RecordSource = @{ type = 'string'; title = 'Calling record source'; enum = @('Both', 'Dataverse', 'SharePoint'); default = 'Both' }
    PrimaryKeyMap = @{ type = 'string'; title = 'Dataverse actual primary-key JSON map (optional)' }
    LastDays = @{ type = 'integer'; title = 'Last days (ignored when either UTC boundary is supplied)'; default = 7 }
    FromUtc = @{ type = 'string'; title = 'From UTC, inclusive run start (ISO 8601)' }
    ToUtc = @{ type = 'string'; title = 'To UTC, exclusive run start (ISO 8601)' }
    ExportFormat = @{ type = 'string'; title = 'Export format'; enum = @('Both', 'CSV', 'JSON'); default = 'Both' }
    AsAdmin = @{ type = 'boolean'; title = 'Use administrator discovery/history'; default = $false }
    ExcludedFlowIds = @{ type = 'string'; title = 'Additional helper flow IDs to exclude, comma separated' }
    MaxWorkItems = @{ type = 'integer'; title = 'Maximum queued work items (1-5000)'; default = 1000 }
    MaxRuns = @{ type = 'integer'; title = 'Maximum selected runs (1-10000)'; default = 100 }
}
$definition = [ordered]@{
    '$schema' = 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
    contentVersion = '1.0.0.0'
    parameters = [ordered]@{
        '$authentication' = @{ type = 'SecureObject'; defaultValue = @{} }
        '$connections' = @{ type = 'Object'; defaultValue = @{} }
    }
    triggers = @{ manual = @{ type = 'Request'; kind = 'Button'; inputs = @{ schema = @{ type = 'object'; properties = $properties } } } }
    actions = $actions
    outputs = @{}
}
if ($UseSolutionEnvironmentVariables) {
    foreach ($setting in $configuration) {
        $definition.parameters[$setting.ParameterName] = @{
            type = 'String'
            defaultValue = $setting.DefaultValue
            metadata = @{ schemaName = $setting.SchemaName; description = $setting.Description }
        }
    }
}
$references = [ordered]@{}
foreach ($connector in @('shared_webcontents', 'shared_sharepointonline')) {
    $connection = $WebContentsConnectionName
    if ($connector -eq 'shared_sharepointonline') { $connection = $SharePointConnectionName }
    $references[$connector] = @{
        connectionName = $connection; source = 'Embedded'
        id = "/providers/Microsoft.PowerApps/apis/$connector"; tier = 'NotSpecified'
    }
}
$package = [pscustomobject][ordered]@{
    displayName = 'Flow Run History Collector'
    state = 'Stopped'
    targetTenantId = $(if ($UseSolutionEnvironmentVariables) { $null } else { $TenantId.ToString() })
    targetCloud = $cloudProfile.Name
    definition = $definition
    connectionReferences = $references
    deployment = @{
        automaticDeployment = $false
        placeholdersRemain = ($WebContentsConnectionName.StartsWith('REPLACE_') -or $SharePointConnectionName.StartsWith('REPLACE_'))
        requiredFlowResource = $cloudProfile.Audience
        requiredFlowBase = $apiBase
        requiredIdentityAuthority = $cloudProfile.Authority
        requiredIdentityEnvironment = $cloudProfile.AzEnvironment
        contentHostSuffixes = $cloudProfile.ContentSuffixes
        publicUserContentStorageAllowed = ($cloudProfile.Name -eq 'Public')
        gccBestEffortOfflineOnly = ($cloudProfile.Name -eq 'GCC')
        reportSite = $(if ($UseSolutionEnvironmentVariables) { $null } else { $site })
        reportFolderPath = $ReportFolderPath
        configurationMode = $(if ($UseSolutionEnvironmentVariables) { 'SolutionEnvironmentVariables' } else { 'Fixed' })
        environmentVariables = $(if ($UseSolutionEnvironmentVariables) { $configuration } else { @() })
        warning = 'Connections, tenant, DLP, premium licensing and existing folder must be verified before parent-owned deployment.'
    }
}
if ($OutputPath) {
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $stream = [IO.File]::Open($resolved, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $writer = $null
    try {
        $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
        $writer.WriteLine((ConvertTo-Json -InputObject $package -Depth 100))
    }
    finally {
        if ($null -ne $writer) { $writer.Dispose() }
        else { $stream.Dispose() }
    }
}
$package

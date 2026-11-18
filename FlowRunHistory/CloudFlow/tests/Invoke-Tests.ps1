#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ResultsPath,
    [ValidateSet('Public', 'GCC')][string]$Cloud = 'Public'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$generator = Join-Path $PSScriptRoot '..\New-FlowHistoryCollector.ps1'
$parameters = @{
    TenantId = '11111111-1111-4111-8111-111111111111'
    SharePointSiteUrl = 'https://contoso.sharepoint.com/sites/Test'
    Cloud = $Cloud
}
$expectedCloud = if ($Cloud -eq 'GCC') { 'GCC' } else { 'Public' }
$expectedApiBase = if ($Cloud -eq 'GCC') { 'https://gov.api.flow.microsoft.us' } else { 'https://api.flow.microsoft.com' }
$otherApiBase = if ($Cloud -eq 'GCC') { 'https://api.flow.microsoft.com' } else { 'https://gov.api.flow.microsoft.us' }
$package = & $generator @parameters
$actions = @{}
$expressions = [Collections.Generic.List[string]]::new()
$results = [Collections.Generic.List[object]]::new()
$script:maxDepth = 0

function Assert {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $results.Add(@{ Name = $Name; Passed = $true }); Write-Host "PASS $Name" }
    catch { $results.Add(@{ Name = $Name; Passed = $false; Error = $_.Exception.Message }); Write-Host "FAIL $Name : $($_.Exception.Message)"; Write-Host $_.ScriptStackTrace }
}

function Collect-Actions {
    param($Map, [int]$Depth = 1, [hashtable]$Target = $actions)
    $script:maxDepth = [Math]::Max($script:maxDepth, $Depth)
    foreach ($entry in $Map.GetEnumerator()) {
        Assert (-not $Target.ContainsKey($entry.Key)) "Duplicate global action name: $($entry.Key)"
        $Target[$entry.Key] = $entry.Value
        $action = $entry.Value
        foreach ($previous in $action.runAfter.Keys) {
            Assert ($Map.Contains($previous)) "runAfter references an action outside its sibling scope: $previous"
        }
        if ($action.Contains('actions')) { Collect-Actions $action.actions ($Depth + 1) $Target }
        if ($action.Contains('else')) { Collect-Actions $action.else.actions ($Depth + 1) $Target }
        if ($action.Contains('cases')) { foreach ($case in $action.cases.Values) { Collect-Actions $case.actions ($Depth + 1) $Target } }
        if ($action.Contains('default')) { Collect-Actions $action.default.actions ($Depth + 1) $Target }
    }
}

function Collect-Expressions {
    param($Value)
    if ($Value -is [string]) {
        if ($Value.StartsWith('@')) { $expressions.Add($Value) }
    }
    elseif ($Value -is [Collections.IDictionary]) { foreach ($item in $Value.Values) { Collect-Expressions $item } }
    elseif ($Value -is [Collections.IEnumerable]) { foreach ($item in $Value) { Collect-Expressions $item } }
}

function Assert-NoExplicitSecureData {
    param($Value)
    if ($Value -is [Collections.IDictionary]) {
        Assert (-not $Value.Contains('secureData')) 'Explicit secureData remains in the generated action/trigger tree.'
        foreach ($item in $Value.Values) { Assert-NoExplicitSecureData $item }
    }
    elseif ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        foreach ($item in $Value) { Assert-NoExplicitSecureData $item }
    }
}

function Check-NativeCondition {
    param($Condition)
    if ($Condition -is [string]) { return }
    Assert ($Condition -is [Collections.IDictionary]) 'Native condition must be an expression string or operator object.'
    foreach ($operator in $Condition.Keys) {
        if ($operator -in @('and', 'or')) {
            foreach ($child in $Condition[$operator]) { Check-NativeCondition $child }
        }
        elseif ($operator -eq 'not') { Check-NativeCondition $Condition[$operator] }
        else {
            foreach ($operand in $Condition[$operator]) {
                Assert ($operand -isnot [array] -and $operand -isnot [Collections.IList]) "Native condition '$operator' contains an unsupported literal array operand; use createArray(...) inside a WDL expression string."
            }
        }
    }
}

# Deliberately small test-only WDL parser/evaluator. Fixtures execute the generated
# expressions, not a second implementation of selection/identity/security logic.
function Parse-WdlNode {
    param($State)
    if ($State.Index -ge $State.Tokens.Count) { throw 'Unexpected end of expression.' }
    $token = $State.Tokens[$State.Index++]
    if ($token.StartsWith("'")) { $node = @{ Kind = 'Literal'; Value = $token.Substring(1, $token.Length - 2).Replace("''", "'") } }
    elseif ($token -match '^-?\d') { $node = @{ Kind = 'Literal'; Value = [double]::Parse($token, [Globalization.CultureInfo]::InvariantCulture) } }
    elseif ($token -in @('true', 'false', 'null')) {
        $value = $null
        if ($token -eq 'true') { $value = $true }
        if ($token -eq 'false') { $value = $false }
        $node = @{ Kind = 'Literal'; Value = $value }
    }
    else {
        Assert ($State.Tokens[$State.Index++] -eq '(') "Expected '(' after $token"
        $arguments = [Collections.Generic.List[object]]::new()
        if ($State.Tokens[$State.Index] -ne ')') {
            $arguments.Add((Parse-WdlNode $State))
            while ($State.Tokens[$State.Index] -eq ',') { $State.Index++; $arguments.Add((Parse-WdlNode $State)) }
        }
        Assert ($State.Tokens[$State.Index++] -eq ')') "Expected ')' for $token"
        $node = @{ Kind = 'Call'; Name = $token; Arguments = $arguments.ToArray() }
    }
    while ($State.Index -lt $State.Tokens.Count -and $State.Tokens[$State.Index] -in @('?', '[')) {
        if ($State.Tokens[$State.Index] -eq '?') { $State.Index++ }
        Assert ($State.Tokens[$State.Index++] -eq '[') "Expected property index."
        $index = Parse-WdlNode $State
        Assert ($State.Tokens[$State.Index++] -eq ']') "Expected closing property index."
        $node = @{ Kind = 'Index'; Source = $node; Index = $index }
    }
    return $node
}

function Parse-Wdl {
    param([string]$Text)
    $textBody = $Text.TrimStart('@')
    $tokens = [Collections.Generic.List[string]]::new()
    $position = 0
    while ($position -lt $textBody.Length) {
        $match = [regex]::Match($textBody.Substring($position), "^\s*('(?:''|[^'])*'|-?\d+(?:\.\d+)?|[A-Za-z_][A-Za-z0-9_]*|[(),?\[\]])")
        Assert $match.Success "Invalid WDL token at $position in $Text"
        $tokens.Add($match.Groups[1].Value); $position += $match.Length
    }
    $state = @{ Tokens = $tokens.ToArray(); Index = 0 }
    $node = Parse-WdlNode $state
    Assert ($state.Index -eq $state.Tokens.Count) "Trailing expression tokens: $Text"
    return $node
}

function Wdl-String {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
    return ConvertTo-Json -InputObject $Value -Depth 100 -Compress
}

function Wdl-Index {
    param($Object, $Key)
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) {
        foreach ($name in $Object.Keys) { if ([string]$name -ceq [string]$Key) { return ,$Object[$name] } }
        return $null
    }
    if ($Object -is [array] -or $Object -is [Collections.IList]) {
        $number = [int]$Key
        if ($number -ge 0 -and $number -lt $Object.Count) { return ,$Object[$number] }
        return $null
    }
    $property = @($Object.PSObject.Properties | Where-Object Name -CEQ ([string]$Key))
    if ($property.Count -gt 0) { return ,$property[0].Value }
    return $null
}

function Eval-Wdl {
    param($Node, $Context)
    if ($Node.Kind -eq 'Literal') { return ,$Node.Value }
    if ($Node.Kind -eq 'Index') { return Wdl-Index (Eval-Wdl $Node.Source $Context) (Eval-Wdl $Node.Index $Context) }
    $name = $Node.Name.ToLowerInvariant()
    if ($name -eq 'if') {
        if (Eval-Wdl $Node.Arguments[0] $Context) { return Eval-Wdl $Node.Arguments[1] $Context }
        return Eval-Wdl $Node.Arguments[2] $Context
    }
    $args = [Collections.Generic.List[object]]::new()
    foreach ($argument in $Node.Arguments) { $args.Add((Eval-Wdl $argument $Context)) }
    switch ($name) {
        'variables' { return Wdl-Index $Context.Variables $args[0] }
        'parameters' { return Wdl-Index $Context.Parameters $args[0] }
        'outputs' { return Wdl-Index $Context.Outputs $args[0] }
        'body' { return Wdl-Index $Context.Bodies $args[0] }
        'triggerbody' { return ,$Context.Trigger }
        'item' { return ,$Context.Item }
        'items' { return Wdl-Index $Context.Items $args[0] }
        'workflow' { return ,$Context.Workflow }
        'coalesce' { foreach ($value in $args) { if ($null -ne $value) { return ,$value } }; return $null }
        'string' { return Wdl-String $args[0] }
        'tolower' { return (Wdl-String $args[0]).ToLowerInvariant() }
        'trim' { return (Wdl-String $args[0]).Trim() }
        'concat' { return (($args | ForEach-Object { Wdl-String $_ }) -join '') }
        'join' { return (($args[0] | ForEach-Object { Wdl-String $_ }) -join [string]$args[1]) }
        'replace' { return (Wdl-String $args[0]).Replace([string]$args[1], [string]$args[2]) }
        'split' { return ,((Wdl-String $args[0]).Split(@([string]$args[1]), [StringSplitOptions]::None)) }
        'first' { return ,$args[0][0] }
        'last' { return ,$args[0][-1] }
        'createarray' { return ,$args.ToArray() }
        'union' {
            $values = [Collections.Generic.List[object]]::new()
            foreach ($collection in $args) {
                foreach ($value in $collection) { if ($value -cnotin $values.ToArray()) { $values.Add($value) } }
            }
            return ,$values.ToArray()
        }
        'json' { $parsed = [string]$args[0] | ConvertFrom-Json; return ,$parsed }
        'empty' {
            if ($null -eq $args[0]) { return $true }
            if ($args[0] -is [string]) { return $args[0].Length -eq 0 }
            return $args[0].Count -eq 0
        }
        'length' { if ($args[0] -is [string]) { return $args[0].Length }; return $args[0].Count }
        'contains' {
            if ($args[0] -is [string]) { return $args[0].Contains([string]$args[1]) }
            if ($args[0] -is [Collections.IDictionary]) { return [string]$args[1] -cin @($args[0].Keys) }
            return $args[1] -cin @($args[0])
        }
        'startswith' { return (Wdl-String $args[0]).StartsWith([string]$args[1], [StringComparison]::Ordinal) }
        'endswith' { return (Wdl-String $args[0]).EndsWith([string]$args[1], [StringComparison]::Ordinal) }
        'equals' { return $args[0] -ceq $args[1] }
        'not' { return -not [bool]$args[0] }
        'and' { return -not ($false -in @($args | ForEach-Object { [bool]$_ })) }
        'or' { return $true -in @($args | ForEach-Object { [bool]$_ }) }
        'greater' { return $args[0] -gt $args[1] }
        'greaterorequals' { return $args[0] -ge $args[1] }
        'less' { return $args[0] -lt $args[1] }
        'lessorequals' { return $args[0] -le $args[1] }
        'ticks' { return [DateTimeOffset]::Parse([string]$args[0], [Globalization.CultureInfo]::InvariantCulture).UtcDateTime.Ticks }
        'adddays' { return [DateTimeOffset]::Parse([string]$args[0]).AddDays([double]$args[1]).ToString('o') }
        'formatdatetime' { return [DateTimeOffset]::Parse([string]$args[0], [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime().ToString([string]$args[1], [Globalization.CultureInfo]::InvariantCulture) }
        'mul' { return [double]$args[0] * [double]$args[1] }
        'sub' { return [double]$args[0] - [double]$args[1] }
        'div' { return [double]$args[0] / [double]$args[1] }
        'int' { return [int]$args[0] }
        'float' { return [double]$args[0] }
        'isint' { $number = 0L; return [long]::TryParse([string]$args[0], [ref]$number) }
        'substring' { return (Wdl-String $args[0]).Substring([int]$args[1], [int]$args[2]) }
        'urischeme' { return ([uri][string]$args[0]).Scheme }
        'urihost' { return ([uri][string]$args[0]).Host }
        'uriport' { return ([uri][string]$args[0]).Port }
        'uripath' { return ([uri][string]$args[0]).AbsolutePath }
        'uricomponent' { return [uri]::EscapeDataString([string]$args[0]) }
        'base64' { return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Wdl-String $args[0]))) }
        default { throw "Fixture evaluator does not implement $name; it must never execute arbitrary code." }
    }
}

function Context {
    return @{
        Variables = @{}; Outputs = @{}; Bodies = @{}; Trigger = @{}; Items = @{}; Item = $null; Parameters = @{}
        Workflow = @{ name = '33333333-3333-4333-8333-333333333333'; run = @{ name = 'fixture-run' }; tags = @{ environmentName = 'fixture-environment' } }
    }
}

function Evaluate {
    param([string]$Expression, $Context)
    return Eval-Wdl (Parse-Wdl $Expression) $Context
}

Collect-Actions $package.definition.actions
Collect-Expressions $package.definition
Test-Case 'All generated native expressions parse without unbound PowerShell interpolation' {
    foreach ($expression in $expressions) { $null = Parse-Wdl $expression; Assert ($expression.Length -le 8192) 'Expression exceeds native length.' }
}
Test-Case 'Native condition JSON has no literal array operands; enum arrays use WDL createArray' {
    foreach ($action in $actions.Values) {
        if ($action.Contains('expression')) { Check-NativeCondition $action.expression }
    }
    $caught = $false
    try { Check-NativeCondition @{ contains = @(@('Summary', 'All'), "@variables('Mode')") } }
    catch { $caught = $_.Exception.Message -match 'unsupported literal array operand' }
    Assert $caught 'The real platform literal-array condition rejection was not reproduced by the regression.'
}
Test-Case 'Definition stays within 500 actions/eight levels and uses a bounded flat queue' {
    Assert ($actions.Count -le 500 -and $maxDepth -le 8) "Native limits violated: $($actions.Count) actions, $maxDepth levels."
    Assert ($actions.ContainsKey('Queue_run_expansion') -and $actions.ContainsKey('Dispatch_work_kind')) 'Flat work expansion missing.'
    Assert ($actions.Process_bounded_work_queue.limit.count -eq 5000) 'Until limit is not explicit.'
    Assert ($actions.Traversal_limit_reached.inputs.value.State -eq 'CollectorLimitReached') 'Cap exhaustion lacks a visible coverage issue.'
}
Test-Case 'Native Button and Embedded authentication remain while every explicit secure-I/O setting is absent' {
    Assert ($package.state -eq 'Stopped' -and $package.deployment.placeholdersRemain) 'Generator must not deploy or infer bindings.'
    Assert ($package.definition.triggers.manual.kind -eq 'Button') 'Wrong trigger.'
    Assert ($package.definition.parameters.'$authentication'.type -eq 'SecureObject') 'Missing authentication parameter.'
    foreach ($reference in $package.connectionReferences.Values) { Assert ($reference.source -eq 'Embedded') 'Invoker binding forbidden.' }
    foreach ($action in $actions.Values) {
        if ($action.type -eq 'Foreach') {
            Assert ($action.runtimeConfiguration.concurrency.repetitions -eq 1) 'Shared accumulation is not sequential.'
            Assert ($action.foreach.StartsWith('@range(')) 'Foreach must expose indices, not raw payloads, to control history.'
        }
        Assert-NoExplicitSecureData $package.definition
        Assert ($package.definition.parameters.'$authentication'.type -ceq 'SecureObject') 'SecureObject is a required authentication type, not a removable I/O setting.'
    }
}
Test-Case 'Unsecurable variables queue metadata selectors only, never raw metadata or signed-link state' {
    foreach ($action in $actions.Values) {
        if ($action.type -in @('InitializeVariable', 'SetVariable', 'AppendToArrayVariable', 'IncrementVariable')) {
            $serialized = ConvertTo-Json -InputObject $action.inputs -Depth 60 -Compress
            Assert ($serialized -notmatch "body\('Read_Flow_API'\)|body\('Read_signed_payload_anonymously'\)|outputs\('Raw_selected_payload'\)|outputs\('Payload_link_uri'\)|RawPayloadState|\?\['(?:inputsLink|outputsLink)'\]") 'Raw private data is copied into an unsecurable variable action.'
        }
        if ($action.type -eq 'AppendToArrayVariable' -and $action.inputs.name -eq 'WorkQueue' -and
            $action.inputs.value -is [Collections.IDictionary]) {
            Assert (-not $action.inputs.value.Contains('Properties') -and -not $action.inputs.value.Contains('Inline')) 'Work queue still copies raw operation properties.'
            if ($action.inputs.value.Contains('RunEnvelope')) {
                $fields = @($action.inputs.value.RunEnvelope.properties.Keys)
                Assert (@($fields | Where-Object { $_ -notin @('status', 'code', 'startTime', 'endTime', 'correlation') }).Count -eq 0) 'Run-list summary contains unselected raw fields.'
            }
        }
    }
    Assert ($actions.Read_signed_payload_anonymously.inputs.uri -eq "@outputs('Payload_link_uri')") 'Signed URI should be resolved directly, not placed in variable state.'
    Assert ($actions.Add_payload_record.inputs.value.Content -eq "@outputs('Safe_payload_for_report')") 'Business report accumulation bypasses the selected safe projection.'
    Assert ($actions.New_trigger_data.inputs -match "outputs\('Safe_trigger_fields'\)") 'Record context stores raw source payloads instead of whitelisted scalar identity fields.'
    Assert (-not ($package.definition.actions.Initialize_ResponseState.inputs.variables[0].value.Contains('Body'))) 'Response variable stores a raw response body.'
    Assert ($actions.Compose_report_manifest.inputs.RunHistoryLimitation -match 'No explicit Secure Inputs/Outputs' -and
        $actions.Compose_report_manifest.inputs.RunHistoryLimitation -match 'signed links') 'Explicitly unsecured run-history/co-owner limitation is hidden.'
}
Test-Case 'Only Flow GET and approved SharePoint file actions are connector operations' {
    foreach ($action in $actions.Values) {
        if ($action.type -eq 'OpenApiConnection') {
            Assert (-not $action.inputs.Contains('authentication')) 'Action-level authentication must not be injected.'
            if ($action.inputs.host.apiId.EndsWith('/shared_webcontents')) {
                Assert ($action.inputs.parameters['request/method'] -eq 'GET') 'Collector mutates source APIs.'
                Assert (-not $action.inputs.parameters.Contains('request/body')) 'GET has a request body.'
            }
            else { Assert ($action.inputs.host.operationId -in @('CreateFile', 'GetFileContentByPath')) 'Unexpected write/connector operation.' }
        }
        if ($action.type -eq 'Http') { Assert (-not $action.inputs.Contains('authentication') -and -not $action.inputs.Contains('headers')) 'Signed content request can forward credentials.' }
    }
}
Test-Case 'Manual status/flow/run parsing and environment defaults retain practical selection' {
    $c = Context
    $c.Trigger = @{ Status = 'Failed, CANCELLED'; FlowIds = 'a, b'; RunIds = 'run1, run2' }
    $status = Evaluate $actions.Initialize_Statuses.inputs.variables[0].value $c
    Assert (@($status).Count -eq 2 -and $status[0] -ceq 'failed' -and $status[1] -ceq 'cancelled') 'Status normalization failed.'
    Assert (@(Evaluate $actions.Initialize_FlowIds.inputs.variables[0].value $c).Count -ge 1) 'Flow list parsing failed.'
    Assert ((Evaluate $actions.Initialize_EnvironmentId.inputs.variables[0].value $c) -eq 'fixture-environment') 'Current environment default lost.'
    Assert ($actions.Queue_flow_discovery.actions.Queue_flow_discovery_append.inputs.value.Uri -match 'includeSolutionCloudFlows') 'Solution discovery missing.'
}
Test-Case 'Verified self-exclusion resolves distinct runtime/resource and workflow aliases before discovery' {
    $c = Context
    $runtimeId = '33333333-3333-4333-8333-333333333333'
    $workflowAlias = '44444444-4444-4444-8444-444444444444'
    $helperId = '55555555-5555-4555-8555-555555555555'
    $c.Variables.ExcludedFlowIds = @($runtimeId, $helperId)
    $c.Variables.EnvironmentId = 'a-different-scan-environment'
    $c.Bodies.Resolve_collector_identity = @{
        name = $workflowAlias
        properties = @{ resourceId = $runtimeId; workflowEntityId = $workflowAlias }
    }
    $uri = Evaluate $actions.Resolve_collector_identity.inputs.parameters['request/url'] $c
    Assert ($uri -match '/environments/fixture-environment/flows/33333333-3333-4333-8333-333333333333\?') 'Own lookup incorrectly used the optional scan-environment override.'
    Assert ([bool](Evaluate $actions.Verify_collector_identity.expression.equals[0] $c)) 'Verified native/resource mapping rejected.'
    $excluded = Evaluate $actions.Compose_verified_excluded_ids.inputs $c
    Assert ($runtimeId -cin $excluded -and $workflowAlias -cin $excluded -and $helperId -cin $excluded) 'Self alias/resource or manual helper exclusion lost.'
    Assert (@($excluded).Count -eq 3) 'Verified exclusions are not de-duplicated.'
    $c.Bodies.Resolve_collector_identity.properties.resourceId = '66666666-6666-4666-8666-666666666666'
    Assert (-not [bool](Evaluate $actions.Verify_collector_identity.expression.equals[0] $c)) 'Mismatched resource mapping was trusted.'
    $c.Bodies.Resolve_collector_identity.properties.resourceId = $runtimeId
    $c.Bodies.Resolve_collector_identity.properties.workflowEntityId = ''
    Assert (-not [bool](Evaluate $actions.Verify_collector_identity.expression.equals[0] $c)) 'Missing workflow alias was trusted.'
    Assert ($actions.Stop_unverified_self_identity.inputs.runStatus -eq 'Failed') 'Unverified self-exclusion can proceed silently.'
    Assert ($actions.Seed_empty_selection_guard.runAfter.ContainsKey('Set_verified_excluded_ids')) 'Discovery can begin before verified exclusions are stored.'
}
Test-Case 'Explicit UTC boundaries override default LastDays, including an open boundary' {
    $c = Context; $c.Variables.SnapshotUtc = '2026-11-18T12:00:00Z'; $c.Trigger.LastDays = 7
    Assert ((Evaluate $actions.Set_window_from.inputs.value $c) -like '2026-11-11T12:00:00*') 'Rolling UTC window failed.'
    $c.Trigger.ToUtc = '2026-11-18T00:00:00Z'
    Assert ((Evaluate $actions.Set_window_from.inputs.value $c) -eq '') 'Explicit To should suppress default rolling From.'
    $c.Trigger.FromUtc = '2026-11-10T00:00:00Z'
    Assert ((Evaluate $actions.Set_window_from.inputs.value $c) -eq $c.Trigger.FromUtc) 'Explicit From ignored.'
}
Test-Case 'Generated run filter tests inclusive/exclusive UTC starts and preserves actual failure status' {
    $c = Context; $c.Variables.Statuses = @('failed'); $c.Variables.FromUtc = '2026-11-10T00:00:00Z'; $c.Variables.ToUtc = '2026-11-18T00:00:00Z'
    foreach ($test in @(@('2026-11-10T00:00:00Z', $true), @('2026-11-09T23:59:59Z', $false), @('2026-11-18T00:00:00Z', $false))) {
        $c.Outputs.Current_run_properties = @{ status = 'Failed'; code = 'ActionFailed'; startTime = $test[0] }
        Assert ((Evaluate $actions.Run_matches_filters.inputs $c) -eq $test[1]) "UTC boundary failed: $($test[0])"
    }
    $c.Variables.Statuses = @('terminated'); $c.Outputs.Current_run_properties = @{ status = 'Failed'; code = 'Terminated'; startTime = '2026-11-11T00:00:00Z' }
    Assert ([bool](Evaluate $actions.Run_matches_filters.inputs $c)) 'Literal Terminated run code should match without relabeling status.'
}
Test-Case 'CallingRecordId queues no action collection and payload mode distinguishes failed outputs from inputs' {
    $c = Context; $c.Variables.Mode = 'CallingRecordId'; $c.Variables.IncludeRecord = $true
    Assert (-not [bool](Evaluate $actions.Need_action_details.expression.equals[0] $c)) 'Record-only requests action histories.'
    $c.Variables.Mode = 'Errors'; $c.Variables.CurrentWork = @{ OperationType = 'Action' }
    $c.Outputs.Current_operation_properties = @{ status = 'Failed' }
    $c.Outputs.Payload_side = 'inputs'
    Assert (-not [bool](Evaluate $actions.Need_this_payload_side.expression.equals[0] $c)) 'Errors mode requests action inputs.'
    $c.Outputs.Payload_side = 'outputs'
    Assert ([bool](Evaluate $actions.Need_this_payload_side.expression.equals[0] $c)) 'Errors mode misses failing action output.'
}
Test-Case 'Content origin guard accepts Microsoft storage and rejects lookalikes, ports and credentials' {
    $c = Context; $c.Variables.CurrentWork = @{}
    foreach ($test in @(
        @('https://prod.logic.azure.com/workflows/x?sig=secret', ($Cloud -eq 'Public')),
        @('https://abcd.05.environment.api.powerplatformusercontent.com/storage/powerautomate/automations/x?sig=secret', ($Cloud -eq 'Public')),
        @('https://prod.logic.azure.com.evil.invalid/x?sig=secret', $false),
        @('https://abcd.05.environment.api.powerplatformusercontent.com/elsewhere', $false),
        @('http://prod.logic.azure.com/x', $false), @('https://prod.logic.azure.com:444/x', $false),
        @('https://user:password@prod.logic.azure.com/x', $false)
    )) {
        $c.Outputs.Payload_link_uri = $test[0]
        Assert ((Evaluate $actions.Guard_anonymous_content_origin.expression.equals[0] $c) -eq $test[1]) "Content origin test failed: $($test[0])"
    }
}
Test-Case 'Payload secret-marker policy withholds entire exports without blocking safe ID/error projections' {
    $c = Context
    foreach ($value in @(@{ headers = @{ Authorization = 'Bearer secret' }; body = @{ accountid = 'row' } },
        @{ uri = 'https://example.invalid/x?sig=secret' }, @{ headers = @{ Cookie = 'session=secret' } },
        @{ parameters = @{ password = 'secret'; 'api-key' = 'secret' } })) {
        $c.Outputs.Raw_selected_payload = $value
        Assert ([bool](Evaluate $actions.Payload_contains_sensitive_marker.expression.equals[0] $c)) 'Unsafe payload marker not recognized.'
    }
    $c.Outputs.Raw_selected_payload = @{ body = @{ ID = 5; Title = 'Synthetic' } }
    Assert (-not [bool](Evaluate $actions.Payload_contains_sensitive_marker.expression.equals[0] $c)) 'Normal business body incorrectly withheld.'
    Assert ($actions.Store_trigger_data.inputs.value -match 'New_trigger_data') 'Private ID projection context missing.'
    Assert ($actions.New_trigger_data.inputs -match 'Safe_trigger_fields') 'Record-only context should store only its safe identity projection.'
}
Test-Case 'Dataverse candidates use canonical or mapped actual keys, not arbitrary/lookup GUIDs' {
    $c = Context; $c.Outputs.Runtime_table_name = 'account'; $c.Variables.PrimaryKeys = @{ account = 'accountid' }
    $id = '12345678-1234-4234-8234-123456789abc'
    $c.Variables.CurrentWork = @{ FlowId = 'flow'; RunId = 'run' }
    $c.Variables.TriggerData = @{ 'flow/run' = @{ inputs = @{ Table = 'account' } } }
    $c.Outputs.Private_trigger_body = @{ accountid = $id; _ownerid_value = '99999999-9999-4999-8999-999999999999' }
    $c.Outputs.Private_actual_key_name = Evaluate $actions.Private_actual_key_name.inputs $c
    Assert ((Evaluate $actions.Private_actual_key_value.inputs $c) -eq $id) 'Private projection did not use only the actual mapped primary key.'
    $c.Outputs.Record_output_object = @{ ExplicitKeyValue = $id; CanonicalRecordId = '' }
    $c.Outputs.Canonical_dataverse_uri = ''; $c.Outputs.Mapped_primary_key = Evaluate $actions.Mapped_primary_key.inputs $c
    Assert ((Evaluate $actions.Dataverse_candidate.inputs $c) -eq $id) 'Actual mapped primary key not selected.'
    $c.Outputs.Mapped_primary_key = ''
    Assert ((Evaluate $actions.Dataverse_candidate.inputs $c) -eq '') 'Lookup/arbitrary GUID guessed as a primary key.'
    $c.Outputs.Private_canonical_identity = "https://org.crm.dynamics.com/api/data/v9.2/accounts($id)"
    $c.Outputs.Canonical_dataverse_uri = Evaluate $actions.Private_canonical_candidate.inputs $c
    $c.Outputs.Dataverse_candidate = Evaluate $actions.Dataverse_candidate.inputs $c
    $c.Outputs.Dataverse_identity_conflicts = Evaluate $actions.Dataverse_identity_conflicts.inputs $c
    $c.Outputs.Runtime_trigger_operation = 'SubscribeWebhookTrigger'; $c.Variables.RecordSource = 'Both'
    Assert ([bool](Evaluate $actions.Verify_dataverse_identity.expression.equals[0] $c)) 'Canonical Dataverse ID rejected.'
    $c.Outputs.Dataverse_candidate = 'not-a-guid'
    Assert (-not [bool](Evaluate $actions.Verify_dataverse_identity.expression.equals[0] $c)) 'Invalid GUID accepted.'
    $c.Outputs.Dataverse_candidate = '99999999-9999-4999-8999-999999999999'
    $c.Outputs.Mapped_primary_key = 'accountid'
    $c.Outputs.Dataverse_identity_conflicts = Evaluate $actions.Dataverse_identity_conflicts.inputs $c
    Assert ([bool]$c.Outputs.Dataverse_identity_conflicts) 'Conflicting canonical/key identities were not detected.'
    Assert (-not [bool](Evaluate $actions.Verify_dataverse_identity.expression.equals[0] $c)) 'Conflicting Dataverse identity was guessed.'
}
Test-Case 'SharePoint IDs are positive top-level numbers with supported operation and source selection' {
    $c = Context; $c.Outputs.Runtime_trigger_operation = 'GetOnNewItems'; $c.Variables.RecordSource = 'Both'
    foreach ($test in @(@('5', $true), @('-1', $false), @('not-an-id', $false), @('', $false))) {
        $c.Outputs.SharePoint_item_id = $test[0]
        Assert ((Evaluate $actions.Verify_sharepoint_identity.expression.equals[0] $c) -eq $test[1]) 'SharePoint numeric/source guard failed.'
    }
}
Test-Case 'Legacy Microsoft.Web runtime API IDs and modern shared connector IDs resolve by exact final segment' {
        $c = Context
        $site = 'https://contoso.sharepoint.com/sites/Test1'
        $list = '88888888-8888-4888-8888-888888888888'
        # Exact live-observed legacy structure; only tenant/site/list identifiers are anonymized.
        $c.Outputs.Private_trigger_object = @{
            host = @{
                apiId = 'subscriptions/11111111-1111-4111-8111-111111111111/providers/Microsoft.Web/locations/westus/runtimes/unitedstates-002/apis/sharepointonline'
                operationId = 'GetOnNewItems'
                connectionReferenceName = 'shared_sharepointonline'
            }
            parameters = @{ dataset = $site; table = $list }
        }
        $c.Outputs.Private_trigger_body = @{ ID = 5 }
        $apiName = Evaluate $actions.Safe_trigger_fields.inputs.ApiName $c
        Assert ($apiName -ceq 'sharepointonline') 'Legacy runtime API suffix was not extracted.'
        $c.Outputs.Record_input_object = @{
            ApiName = $apiName
            OperationId = Evaluate $actions.Safe_trigger_fields.inputs.OperationId $c
            SiteUrl = Evaluate $actions.Safe_trigger_fields.inputs.SiteUrl $c
            ListId = Evaluate $actions.Safe_trigger_fields.inputs.ListId $c
        }
        $c.Outputs.Record_output_object = @{ ItemId = (Evaluate $actions.Safe_trigger_fields.inputs.ItemId $c) }
        $c.Outputs.Runtime_connector_name = Evaluate $actions.Runtime_connector_name.inputs $c
        Assert ((Evaluate $actions.Choose_record_connector.expression $c) -ceq 'shared_sharepointonline') 'Bare legacy SharePoint was classified unsupported.'
        $c.Outputs.Runtime_trigger_operation = Evaluate $actions.Runtime_trigger_operation.inputs $c
        $c.Outputs.SharePoint_item_id = Evaluate $actions.SharePoint_item_id.inputs $c
        $c.Variables.RecordSource = 'Both'
        Assert ([bool](Evaluate $actions.Verify_sharepoint_identity.expression.equals[0] $c)) 'The observed GetOnNewItems/ID5 identity was not accepted.'
        Assert ((Evaluate $actions.Store_sharepoint_identity.inputs.value.RecordId $c) -ceq '5') 'Numeric triggering item ID changed.'
        Assert ((Evaluate $actions.Store_sharepoint_identity.inputs.value.SiteUrl $c) -ceq $site) 'Runtime site context lost.'
        Assert ((Evaluate $actions.Store_sharepoint_identity.inputs.value.ListId $c) -ceq $list) 'Runtime list context lost.'
        foreach ($test in @(
            @('shared_sharepointonline','shared_sharepointonline'), @('sharepointonline','shared_sharepointonline'),
            @('shared_commondataserviceforapps','dataverse'), @('commondataserviceforapps','dataverse'),
            @('shared_commondataservice','dataverse'), @('commondataservice','dataverse'),
            @('untrusted_sharepointonline','untrusted_sharepointonline'), @('sharepointonline_evil','sharepointonline_evil')
        )) {
            $c.Outputs.Runtime_connector_name = $test[0]
            Assert ((Evaluate $actions.Choose_record_connector.expression $c) -ceq $test[1]) 'Connector normalization guessed by substring or omitted an exact runtime alias.'
        }
        $c.Outputs.Runtime_trigger_operation = 'UnsupportedOperation'
        Assert (-not [bool](Evaluate $actions.Verify_sharepoint_identity.expression.equals[0] $c)) 'Connector alias bypassed the actual operation whitelist.'
}
Test-Case 'CSV nested cells remain valid JSON for scalars, arrays, objects and Unicode/newline strings' {
    $c = Context
    $unicode = 'quote " slash \' + "`r`n" + 'caf' + [char]0xE9 + ' ' + [char]0x6771 + [char]0x4EAC
    foreach ($value in @('test', 'plain', $unicode, '', $null, 42, $true, $false, @{ nested = @('a', 'b') }, @('x', 'y'))) {
        $c.Variables.PayloadState = @{ Availability = 'Available' }
        $c.Outputs.Safe_payload_for_report = $value
        $cell = Evaluate $actions.Payload_csv_row.inputs.value.ContentJson $c
        $envelope = ('{"cell":' + $cell + '}') | ConvertFrom-Json
        $decoded = $envelope.cell
        $actual = ConvertTo-Json -InputObject $decoded -Compress -Depth 20
        $expected = ConvertTo-Json -InputObject $value -Compress -Depth 20
        Assert ($actual -eq $expected) "CSV JSON cell lost data or type: expected $expected; cell $cell; decoded $actual."
    }
}
Test-Case 'Exact native SharePoint read-back comparison detects matching and mismatched JSON bytes' {
    $c = Context; $text = '{"Manifest":{"Coverage":"Partial"},"Runs":[]}'
    $c.Outputs.Compose_structured_report = $text | ConvertFrom-Json
    $c.Variables.IdOnly = $false
    $c.Outputs.JSON_export_text = Evaluate $actions.JSON_export_text.inputs $c
    $expected = Wdl-String $c.Outputs.Compose_structured_report
    $c.Bodies.Read_JSON_report_back = @{ '$content' = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($expected)) }
    Assert (-not [bool](Evaluate $actions.JSON_bytes_match.expression.equals[0] $c)) 'Equal bytes were rejected.'
    $c.Bodies.Read_JSON_report_back.'$content' = 'bm90LWVxdWFs'
    Assert ([bool](Evaluate $actions.JSON_bytes_match.expression.equals[0] $c)) 'Mismatched bytes were accepted.'
}
Test-Case 'Report is structured JSON, stable CSV, explicitly partial, and contains no raw link metadata' {
    Assert ($actions.Compose_structured_report.inputs.Runs -eq "@variables('Runs')") 'JSON is a CSV surrogate.'
    Assert ($actions.Compose_structured_report.inputs.Payloads -eq "@variables('Payloads')") 'JSON payload structure missing.'
    Assert ($actions.Compose_report_manifest.inputs.Coverage -match 'Partial') 'Coverage always claims completeness.'
    $headers = @($actions.Create_CSV_table.inputs.columns | ForEach-Object header)
    Assert ('Coverage' -in $headers -and 'TenantId' -in $headers -and 'ContentJson' -in $headers) 'CSV context/coverage missing.'
    foreach ($name in @('Add_selected_run', 'Add_operation')) {
        $json = ConvertTo-Json -InputObject $actions[$name].inputs.value -Depth 30 -Compress
        Assert ($json -notmatch 'inputsLink|outputsLink|Authorization|authentication') 'Raw credential/link metadata exported.'
    }
}
Test-Case 'PowerApp completion and native literal-body driver do not depend on management run payloads' {
    Assert ($actions.Respond_to_parent.type -eq 'Response' -and $actions.Respond_to_parent.kind -eq 'PowerApp') 'Collector lacks the scaffold-verified native child response.'
    Assert ($actions.Respond_to_parent.inputs.statusCode -eq 200) 'Unexpected completion status.'
    $keys = @($actions.Respond_to_parent.inputs.body.Keys)
    Assert (@($keys | Where-Object { $_ -notin @('collectorrunid','collectorruntimeid','reportsite','reportfolder','reportprefix','mode','coverage','selectedruncount','idonly','recordidcount') }).Count -eq 0) 'Child response exposes more than safe completion/configuration identity.'
    $driver = & (Join-Path $PSScriptRoot 'New-CollectorTestDriver.ps1') `
        -CollectorWorkflowId '77777777-7777-4777-8777-777777777777' `
        -InputParameters @{ FlowIds = 'fixture-flow'; RunIds = 'fixture-run'; Mode = 'Errors'; ExportFormat = 'JSON' }
    Assert ($driver.state -eq 'Stopped' -and $driver.definition.triggers.manual.kind -eq 'Button') 'Driver is not a stopped, no-argument native manual flow.'
    Assert ($driver.definition.triggers.manual.inputs.schema.properties.Count -eq 0) 'Driver still relies on an externally transmitted manual body.'
    $call = $driver.definition.actions.Call_collector
    Assert-NoExplicitSecureData $driver.definition
    Assert ($call.type -eq 'Workflow') 'Driver is not native Run a Child Flow.'
    Assert ($call.inputs.host.workflowReferenceName -eq '77777777-7777-4777-8777-777777777777') 'Driver did not use the literal verified workflow GUID.'
    Assert ($call.inputs.body.Mode -eq 'Errors' -and $call.inputs.body.RunIds -eq 'fixture-run') 'Parent-supplied literal body changed.'
    $unknownRejected = $false
    try { $null = & (Join-Path $PSScriptRoot 'New-CollectorTestDriver.ps1') -CollectorWorkflowId '77777777-7777-4777-8777-777777777777' -InputParameters @{ TestInputOverride = 'forbidden' } }
    catch { $unknownRejected = $_.Exception.Message -match 'Unknown collector input' }
    Assert $unknownRejected 'Driver silently accepts a permanent production test override.'
}
Test-Case 'Run-page filters push down safe dates/single status only without explicit run IDs' {
    $c = Context
    $c.Variables.FromUtc = '2026-11-10T00:00:00Z'; $c.Variables.ToUtc = '2026-11-18T00:00:00Z'
    $c.Variables.Statuses = @('failed'); $c.Variables.RunIds = @()
    $clauses = @()
    foreach ($expression in $actions.Candidate_run_filters.inputs) {
        $c.Item = Evaluate $expression $c
        if (Evaluate $actions.Select_nonempty_run_filters.inputs.where $c) { $clauses += $c.Item }
    }
    $c.Bodies.Select_nonempty_run_filters = $clauses
    $c.Outputs.Run_filter_text = Evaluate $actions.Run_filter_text.inputs $c
    $query = [uri]::UnescapeDataString((Evaluate $actions.Run_filter_query.inputs $c))
    Assert ($query.StartsWith('&$filter=')) 'Run history has no encoded server filter.'
    Assert ($query.Contains('startTime ge 2026-11-10T00:00:00.0000000Z') -and $query.Contains('startTime lt 2026-11-18T00:00:00.0000000Z')) 'UTC server boundaries changed.'
    Assert ($query.Contains("status eq 'Failed'")) 'Single supported status was not safely quoted/cased.'
    foreach ($statuses in @(@('failed','cancelled'), @('terminated'))) {
        $c.Variables.Statuses = $statuses
        Assert ((Evaluate $actions.Candidate_run_filters.inputs[2] $c) -eq '') 'Unsupported/multi-status filter was pushed to the service.'
    }
    $c.Variables.RunIds = @('explicit-run')
    Assert ((Evaluate $actions.Run_filter_query.inputs $c) -eq '') 'Explicit run selection was prematurely filtered server-side.'
    Assert ($actions.Queue_explicit_flow_runs_append.inputs.value.Uri -match 'Run_filter_query' -and
        $actions.Queue_discovered_history_append.inputs.value.Uri -match 'Run_filter_query') 'Both explicit-flow and discovered-flow history routes must use the safe filter.'
}
Test-Case 'Irrelevant page summaries never enqueue work; explicit found-before-filter and incomplete summaries remain safe' {
    $c = Context
    $c.Variables.RunIds = @(); $c.Variables.Statuses = @('failed')
    $c.Variables.FromUtc = '2026-11-10T00:00:00Z'; $c.Variables.ToUtc = '2026-11-18T00:00:00Z'
    foreach ($test in @(
        @('Succeeded','2026-11-11T00:00:00Z',$false),
        @('Failed','2026-11-09T23:59:59Z',$false),
        @('Failed','2026-11-18T00:00:00Z',$false),
        @('Failed','2026-11-10T00:00:00Z',$true)
    )) {
        $c.Outputs.RunPage_item = @{ name = 'wanted'; properties = @{ status = $test[0]; startTime = $test[1]; code = 'Known' } }
        Assert ((Evaluate $actions.Select_requested_run_names.expression.equals[0] $c) -eq $test[2]) 'Page-summary preselection consumed irrelevant work or lost a UTC boundary.'
    }
    $c.Variables.Statuses = @('failed','cancelled')
    $c.Outputs.RunPage_item.properties.status = 'Cancelled'
    Assert ([bool](Evaluate $actions.Select_requested_run_names.expression.equals[0] $c)) 'Multi-status local selection failed.'
    $c.Variables.RunIds = @('wanted'); $c.Variables.Statuses = @('failed')
    $c.Outputs.RunPage_item.properties = @{ status = 'Succeeded'; startTime = '2020-01-01T00:00:00Z'; code = 'OK' }
    Assert ([bool](Evaluate $actions.Select_requested_run_names.expression.equals[0] $c)) 'Explicit run existence was hidden by local page filters.'
    Assert ([bool](Evaluate $actions.Record_discovered_requested_name.expression.equals[0] $c)) 'Discovered requested run is not remembered independently of later detail access/filtering.'
    Assert ($actions.Select_requested_run_names.runAfter.ContainsKey('Record_discovered_requested_name')) 'Run existence is recorded after queueing/filtering instead of before.'
    $c.Outputs.Current_run_properties = $c.Outputs.RunPage_item.properties
    Assert (-not [bool](Evaluate $actions.Run_matches_filters.inputs $c)) 'Detail selection trusted the server/page filter instead of rechecking.'
    Assert ($actions.Run_matches_filters.runAfter.ContainsKey('Remember_matched_run_name')) 'Matched name is not recorded before final filtering.'
    $c.Variables.RunIds = @(); $c.Variables.Statuses = @('terminated')
    $c.Outputs.RunPage_item.properties = @{ status = 'Failed'; startTime = '2026-11-12T00:00:00Z' }
    Assert ([bool](Evaluate $actions.Select_requested_run_names.expression.equals[0] $c)) 'Missing summary code was treated as proof the run was not terminated.'
    Assert (-not [bool](Evaluate $actions.Queue_discovered_run_detail_append.inputs.value.RunEnvelopeComplete $c)) 'Incomplete summary must force detail resolution, not cache an invented code.'
}
Test-Case 'Empty GUID sentinel is rejected consistently for canonical, actual-key and unique IDs' {
    $c = Context; $zero = '00000000-0000-0000-0000-000000000000'
    $c.Outputs.Private_canonical_candidate = $zero
    $c.Outputs.Private_actual_key_value = $zero
    $c.Outputs.Private_trigger_body = @{ UniqueId = $zero }
    foreach ($field in @('CanonicalRecordId','ExplicitKeyValue','UniqueId')) {
        Assert ((Evaluate $actions.Safe_trigger_fields.inputs[$field] $c) -eq '') "Zero sentinel accepted for $field."
    }
    $valid = '12345678-1234-4234-8234-123456789abc'
    $c.Outputs.Private_canonical_candidate = $valid
    $c.Outputs.Private_actual_key_value = $valid
    $c.Outputs.Private_trigger_body.UniqueId = $valid
    foreach ($field in @('CanonicalRecordId','ExplicitKeyValue','UniqueId')) {
        Assert ((Evaluate $actions.Safe_trigger_fields.inputs[$field] $c) -ceq $valid) "Valid GUID rejected for $field."
    }
}
Test-Case 'IdOnly is constrained to CallingRecordId and produces minimal verified string arrays and one CSV column' {
    $c = Context
    $rules = @($actions.Validate_manual_inputs.expression.and | Where-Object {
        $_.Contains('equals') -and $_.equals[0] -is [string] -and $_.equals[0].Contains("variables('IdOnly')")
    })
    Assert ($rules.Count -eq 1) 'IdOnly mode validation missing or duplicated.'
    $c.Variables.IdOnly = $true
    foreach ($mode in @('Summary','Errors','All')) {
        $c.Variables.Mode = $mode
        Assert (-not [bool](Evaluate $rules[0].equals[0] $c)) "IdOnly accepted incompatible $mode."
    }
    $c.Variables.Mode = 'CallingRecordId'
    Assert ([bool](Evaluate $rules[0].equals[0] $c)) 'IdOnly rejected CallingRecordId.'
    $c.Variables.CallingRecords = @(
        @{ Identity = @{ Availability = 'Available'; RecordId = '5' } },
        @{ Identity = @{ Availability = 'Unavailable'; RecordId = 'not-verified' } },
        @{ Identity = @{ Availability = 'Available'; RecordId = '' } },
        @{ Identity = @{ Availability = 'Available'; RecordId = '00000000-0000-0000-0000-000000000000' } }
    )
    $verified = @()
    for ($index = 0; $index -lt $c.Variables.CallingRecords.Count; $index++) {
        $c.Items.For_each_minimal_record = $index
        if (Evaluate $actions.Minimal_record_is_verified.expression.equals[0] $c) {
            $verified += Evaluate $actions.Append_verified_record_id.inputs.value $c
        }
    }
    Assert ($verified.Count -eq 1 -and $verified[0] -ceq '5') 'Minimal ID projection invented an unavailable/empty ID.'
    foreach ($ids in @(@(), @('5'), @('5','12345678-1234-4234-8234-123456789abc'))) {
        $c.Variables.RecordIds = $ids
        $text = Evaluate $actions.JSON_export_text.inputs $c
        Assert ($text.StartsWith('[') -and $text.EndsWith(']')) 'ID-only JSON is not an array.'
        if ($ids.Count -eq 0) { Assert ($text -ceq '[]') 'No-ID JSON has a fabricated placeholder.' }
        $decoded = ('{"ids":' + $text + '}') | ConvertFrom-Json
        Assert (@($decoded.ids).Count -eq $ids.Count) 'Minimal JSON cardinality changed.'
    }
    $columns = $actions.Create_minimal_CSV_table.inputs.columns
    Assert ($columns.Count -eq 1 -and $columns[0].header -ceq 'RecordId') 'ID-only CSV contains context columns.'
    Assert ($actions.Select_minimal_CSV_rows.inputs.select.Count -eq 1 -and
        $actions.Select_minimal_CSV_rows.inputs.select.RecordId -ceq '@item()') 'Minimal CSV row projection adds data or rewrites IDs.'
    Assert ($actions.Compose_report_manifest.inputs.IdOnly -and $actions.Respond_to_parent.inputs.body.coverage) 'Minimal files discarded native coverage metadata.'
    $c.Variables.IdOnly = $false
    $c.Outputs.Compose_structured_report = @{ Manifest = @{ Coverage = 'Partial' }; Runs = @() }
    Assert ((Evaluate $actions.JSON_export_text.inputs $c) -ceq (Wdl-String $c.Outputs.Compose_structured_report)) 'Default structured JSON projection changed.'
}
Test-Case 'Generator refuses an existing output artifact and never invokes tenant operations' {
    $path = Join-Path ([IO.Path]::GetTempPath()) ('native-collector-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $null = & $generator @parameters -OutputPath $path
        $original = [IO.File]::ReadAllText($path); $caught = $false
        try { $null = & $generator @parameters -OutputPath $path } catch { $caught = $true }
        Assert ($caught -and [IO.File]::ReadAllText($path) -eq $original) 'Generator overwrote an output artifact.'
    }
    finally { if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } }
    $text = [IO.File]::ReadAllText($generator)
    Assert ($text -notmatch 'Invoke-RestMethod|Connect-AzAccount|create_flow|publish_flow|run_flow') 'Offline generator performs live operations.'
}

Test-Case 'Cloud routing and connection metadata align with the existing reader profiles without a live context' {
    $reader = Join-Path $PSScriptRoot '..\..\Get-FlowRunHistory.ps1'
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($reader, [ref]$tokens, [ref]$parseErrors)
    Assert (@($parseErrors).Count -eq 0) 'Reader profile source does not parse.'
    $profileFunction = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-CloudProfile'
    }, $true)
    Assert ($null -ne $profileFunction) 'Reader cloud-profile prior art was not found.'
    $profile = & $profileFunction.Body.GetScriptBlock() $Cloud
    Assert ($package.targetCloud -ceq $expectedCloud -and $package.targetCloud -ceq $profile.Name) 'Generated package cloud does not match the selected profile.'
    Assert ($package.deployment.requiredFlowBase -ceq $expectedApiBase -and $package.deployment.requiredFlowBase -ceq $profile.ApiBase) 'API host differs from the verified reader mapping.'
    Assert ($package.deployment.requiredFlowResource -ceq $profile.Audience -and $profile.Audience.EndsWith('/')) 'Flow resource/audience or mandatory trailing slash changed.'
    Assert ($package.deployment.requiredIdentityAuthority -ceq 'https://login.microsoftonline.com' -and
        $package.deployment.requiredIdentityAuthority -ceq $profile.Authority) 'Standard GCC must not switch to government Entra identity.'
    Assert ($package.deployment.requiredIdentityEnvironment -ceq 'AzureCloud' -and
        $package.deployment.requiredIdentityEnvironment -ceq $profile.AzEnvironment) 'Standard GCC must not use AzureUSGovernment identity.'
    Assert (@(Compare-Object @($package.deployment.contentHostSuffixes | Sort-Object) @($profile.ContentSuffixes | Sort-Object)).Count -eq 0) 'Native anonymous content families drifted from the reader.'
    Assert ($package.deployment.publicUserContentStorageAllowed -eq ($Cloud -eq 'Public')) 'Commercial user-content storage must not be guessed for GCC.'
    Assert ($package.deployment.gccBestEffortOfflineOnly -eq ($Cloud -eq 'GCC')) 'Best-effort/offline-only GCC scope is not explicit.'
    Assert (-not $package.definition.triggers.manual.inputs.schema.properties.Contains('Cloud')) 'Runtime user input must not switch a bound connection between clouds.'
    foreach ($reference in $package.connectionReferences.Values) { Assert ($reference.source -ceq 'Embedded') 'Cloud selection altered the verified Embedded binding contract.' }
}
Test-Case 'Every generated self, discovery, run, action and repetition route stays on the selected API origin' {
    $c = Context
    $c.Variables.EnvironmentId = 'scan-environment'
    $c.Variables.FlowIds = @('flow-selected'); $c.Variables.RunIds = @('run-selected')
    $c.Variables.CurrentWork = @{
        FlowId = 'flow-from-page'; RunId = 'run-from-page'; OperationName = 'Nested action/with?reserved'
        Uri = "$expectedApiBase/providers/Microsoft.ProcessSimple/environments/scan-environment/flows/flow-from-page/runs/run-from-page?api-version=2016-11-01"
    }
    $c.Outputs.FlowPage_item = @{ name = 'flow-discovered' }
    $c.Outputs.RunPage_item = @{ name = 'run-discovered' }
    $c.Outputs.ActionPage_item = @{ name = 'Action/from?collection' }
    $c.Outputs.Run_filter_query = '&$filter=status%20eq%20%27Failed%27'
    $c.Items.For_each_explicit_flow = 0; $c.Items.For_each_explicit_run = 0
    $c.Variables.Root = Evaluate $actions.Set_api_root.inputs.value $c
    Assert ($c.Variables.Root -ceq "$expectedApiBase/providers/Microsoft.ProcessSimple/environments/scan-environment") 'Non-admin root is not cloud specific.'
    $own = Evaluate $actions.Resolve_collector_identity.inputs.parameters['request/url'] $c
    Assert ($own -ceq "$expectedApiBase/providers/Microsoft.ProcessSimple/environments/fixture-environment/flows/33333333-3333-4333-8333-333333333333?api-version=2016-11-01") 'Own identity resolution switched cloud or used the scan override.'
    foreach ($admin in @($false, $true)) {
        $c.Trigger.AsAdmin = $admin
        $c.Variables.Root = Evaluate $actions.Set_api_root.inputs.value $c
        foreach ($name in @('Queue_flow_discovery_append', 'Queue_shared_discovery_append',
            'Queue_explicit_run_append', 'Queue_explicit_flow_runs_append', 'Queue_discovered_history_append',
            'Queue_discovered_run_detail_append', 'ActionPage_queue_operation_append',
            'Repetitions_queue_operation_append', 'Queue_trigger_operation_append', 'Queue_run_expansion_append',
            'Queue_run_actions_append', 'Queue_selected_payload_append')) {
            $uri = [uri](Evaluate $actions[$name].inputs.value.Uri $c)
            Assert ($uri.GetLeftPart([UriPartial]::Authority) -ceq $expectedApiBase) "$name escaped the selected cloud."
            Assert ($uri.Scheme -ceq 'https' -and $uri.Port -eq 443 -and -not $uri.UserInfo) "$name does not use a credential-free HTTPS API selector."
            Assert ($uri.AbsolutePath.Contains('/environments/scan-environment/')) "$name lost environment association."
        }
        $discovery = Evaluate $actions.Queue_flow_discovery_append.inputs.value.Uri $c
        Assert ($discovery.Contains('/scopes/admin/') -eq $admin) 'Admin discovery root changed.'
        Assert ($discovery.Contains('/v2/flows') -eq $admin) 'Admin v2 discovery contract changed.'
    }
    foreach ($index in @(0, 1)) {
        $c.Items.For_each_repetition_kind = $index
        $uri = Evaluate $actions.Queue_operation_repetitions_append.inputs.value.Uri $c
        Assert (([uri]$uri).GetLeftPart([UriPartial]::Authority) -ceq $expectedApiBase) 'Repetition expansion switched clouds.'
        $kind = @('repetitions', 'scopeRepetitions')[$index]
        Assert ($uri.EndsWith("/$kind`?api-version=2016-11-01") -and $uri.Contains('Nested%20action%2Fwith%3Freserved')) 'Repetition kind/name encoding changed.'
    }
    $actualRequest = Evaluate $actions.Read_Flow_API.inputs.parameters['request/url'] $c
    Assert ($actualRequest -ceq $c.Variables.CurrentWork.Uri) 'HTTP connector does not use the cloud-scoped queue selector.'
    $definitionText = ConvertTo-Json -InputObject $package.definition -Depth 100 -Compress
    Assert (-not $definitionText.Contains($otherApiBase)) 'Generated definition still contains a wrong-cloud API literal.'
}
Test-Case 'Authenticated guards reject wrong-cloud, lookalike, credential, fragment, insecure and foreign-environment URLs' {
    $c = Context; $c.Variables.EnvironmentId = 'scan-environment'; $c.Variables.Visited = @()
    $path = '/providers/Microsoft.ProcessSimple/environments/scan-environment/flows/flow/runs'
    $c.Variables.CurrentWork = @{ Kind = 'RunPage'; Uri = '' }
    foreach ($test in @(
        @("$expectedApiBase$path`?api-version=2016-11-01", $true),
        @("$expectedApiBase/providers/Microsoft.ProcessSimple/scopes/admin/environments/scan-environment/flows/flow/runs", $true),
        @("$otherApiBase$path", $false),
        @("$expectedApiBase.evil.invalid$path", $false),
        @("http://$(([uri]$expectedApiBase).Host)$path", $false),
        @("$expectedApiBase`:444$path", $false),
        @("https://user:password@$(([uri]$expectedApiBase).Host)$path", $false),
        @("$expectedApiBase$path#fragment", $false),
        @("$expectedApiBase/providers/Microsoft.ProcessSimple/environments/scan-environment-other/flows/flow/runs", $false),
        @("https://high.api.flow.microsoft.us$path", $false),
        @("https://api.flow.appsplatform.us$path", $false)
    )) {
        $c.Variables.CurrentWork.Uri = $test[0]
        Assert ((Evaluate $actions.Guard_authenticated_origin.expression.equals[0] $c) -eq $test[1]) "Authenticated origin guard failed: $($test[0])"
    }
    $uri = "$expectedApiBase$path"
    $c.Variables.CurrentWork.Uri = $uri; $c.Variables.Visited = @($uri)
    Assert (-not [bool](Evaluate $actions.Guard_authenticated_origin.expression.equals[0] $c)) 'Repeated collection is not bounded.'
    $c.Variables.CurrentWork.Kind = 'Payload'
    Assert ([bool](Evaluate $actions.Guard_authenticated_origin.expression.equals[0] $c)) 'Legitimate same-cloud payload metadata refetch was blocked as a paging cycle.'
}
Test-Case 'Absolute, root-relative and query-relative paging is cloud scoped on every collection' {
    $c = Context; $c.Variables.EnvironmentId = 'scan-environment'; $c.Variables.Visited = @()
    foreach ($kind in @('FlowPage','RunPage','ActionPage','Repetitions')) {
        $path = '/providers/Microsoft.ProcessSimple/environments/scan-environment/flows'
        if ($kind -eq 'RunPage') { $path += '/flow/runs' }
        if ($kind -eq 'ActionPage') { $path += '/flow/runs/run/actions' }
        if ($kind -eq 'Repetitions') { $path += '/flow/runs/run/actions/action/repetitions' }
        $c.Variables.CurrentWork = @{ Kind = $kind; Uri = "$expectedApiBase$path`?api-version=2016-11-01" }
        foreach ($next in @("$expectedApiBase$path`?page=2", "$path`?page=2", '?page=2')) {
            $c.Outputs.Current_response_body = @{ nextLink = $next }
            $resolved = Evaluate $actions[$kind + '_next_uri'].inputs $c
            Assert ($resolved -ceq "$expectedApiBase$path`?page=2") "$kind paging resolved against the wrong cloud."
            $c.Outputs[$kind + '_next_uri'] = $resolved
            Assert ([bool](Evaluate $actions[$kind + '_same_collection'].expression.equals[0] $c)) "$kind rejected valid same-cloud paging."
        }
        $c.Outputs.Current_response_body = @{ '@odata.nextLink' = '?page=3' }
        Assert ((Evaluate $actions[$kind + '_next_uri'].inputs $c) -ceq "$expectedApiBase$path`?page=3") "$kind lost @odata.nextLink support."
        foreach ($next in @("$otherApiBase$path`?page=2", "$expectedApiBase.evil.invalid$path`?page=2",
            "$expectedApiBase`:444$path", "https://user:pass@$(([uri]$expectedApiBase).Host)$path",
            "http://$(([uri]$expectedApiBase).Host)$path", "$expectedApiBase$path#fragment",
            "$expectedApiBase/another-collection", "$expectedApiBase$path`?sig=secret", "$expectedApiBase$path`?access_token=secret")) {
            $c.Outputs.Current_response_body = @{ nextLink = $next }
            $c.Outputs[$kind + '_next_uri'] = Evaluate $actions[$kind + '_next_uri'].inputs $c
            Assert (-not [bool](Evaluate $actions[$kind + '_same_collection'].expression.equals[0] $c)) "$kind admitted unsafe paging: $next"
        }
    }
}
Test-Case 'Anonymous content hosts are selected-cloud only with fail-closed unknown government storage' {
    $c = Context
    foreach ($test in @(
        @('https://prod-01.usgovvirginia.logic.azure.us/workflows/x?sig=secret', 'GCC'),
        @('https://env.api.gov.powerplatform.microsoft.us/storage/x?sig=secret', 'GCC'),
        @('https://gov.api.flow.microsoft.us/storage/x?sig=secret', 'GCC'),
        @('https://account.blob.core.usgovcloudapi.net/container/x?sig=secret', 'GCC'),
        @('https://prod-01.westus.logic.azure.com/workflows/x?sig=secret', 'Public'),
        @('https://env.api.powerplatform.com/storage/x?sig=secret', 'Public'),
        @('https://api.flow.microsoft.com/storage/x?sig=secret', 'Public'),
        @('https://account.blob.core.windows.net/container/x?sig=secret', 'Public'),
        @('https://abcd.05.environment.api.powerplatformusercontent.com/storage/powerautomate/automations/x?sig=secret', 'Public')
    )) {
        $c.Outputs.Payload_link_uri = $test[0]
        Assert ((Evaluate $actions.Guard_anonymous_content_origin.expression.equals[0] $c) -eq ($test[1] -eq $expectedCloud)) "Content origin crossed clouds: $($test[0])"
    }
    foreach ($uri in @(
        'https://logic.azure.us.evil.invalid/x?sig=secret', 'https://evilgov.api.flow.microsoft.us/x?sig=secret',
        'https://example.microsoft.us/x?sig=secret', 'https://env.api.high.powerplatform.microsoft.us/x?sig=secret',
        'https://high.api.flow.microsoft.us/x?sig=secret', 'https://api.flow.appsplatform.us/x?sig=secret',
        'https://env.gov.powerplatformusercontent.mi/storage/x?sig=secret',
        'https://abcd.environment.api.gov.powerplatformusercontent.microsoft.us/storage/powerautomate/automations/x?sig=secret',
        'http://prod.logic.azure.us/x?sig=secret', 'https://prod.logic.azure.us:444/x?sig=secret',
        'https://user:pass@prod.logic.azure.us/x?sig=secret', 'https://prod.logic.azure.us/x?sig=secret#fragment',
        'https://user:pass@prod.logic.azure.com/x?sig=secret', 'https://prod.logic.azure.com/x?sig=secret#fragment'
    )) {
        $c.Outputs.Payload_link_uri = $uri
        Assert (-not [bool](Evaluate $actions.Guard_anonymous_content_origin.expression.equals[0] $c)) "Unsafe/undocumented content host was accepted: $uri"
    }
    Assert ($actions.Mark_blocked_content.inputs.value.Availability -ceq 'BlockedHost') 'Unknown origins do not produce explicit unavailability.'
    Assert (-not $actions.Read_signed_payload_anonymously.inputs.Contains('authentication') -and
        -not $actions.Read_signed_payload_anonymously.inputs.Contains('headers')) 'Cloud selection added authenticated content download.'
}
Test-Case 'Manifest cloud and cloud-independent record/projection behavior remain explicit' {
    Assert ($actions.Compose_report_manifest.inputs.Cloud -ceq $expectedCloud) 'Report manifest mislabels the generated cloud.'
    Assert ($actions.Respond_to_parent.inputs.body.mode -ceq "@variables('Mode')") 'Cloud routing changed completion mode metadata.'
    Assert ($actions.Create_minimal_CSV_table.inputs.columns.Count -eq 1) 'GCC added context to minimal ID-only CSV.'
    $c = Context
    $c.Outputs.Private_trigger_object = @{
        host = @{ apiId = '/providers/Microsoft.PowerApps/apis/shared_commondataserviceforapps'; operationId = 'SubscribeWebhookTrigger' }
    }
    $suffix = Evaluate $actions.Safe_trigger_fields.inputs.ApiName $c
    $c.Outputs.Runtime_connector_name = $suffix
    Assert ((Evaluate $actions.Choose_record_connector.expression $c) -ceq 'dataverse') 'Cloud selection broke exact primary-record connector matching.'
    $id = '12345678-1234-4234-8234-123456789abc'
    foreach ($hostName in @('org.crm.dynamics.com','org.crm9.dynamics.com')) {
        $c.Outputs.Private_canonical_identity = "https://$hostName/api/data/v9.2/accounts($id)"
        Assert ((Evaluate $actions.Private_canonical_candidate.inputs $c) -ceq $id) 'Canonical ID parsing became incorrectly coupled to an API hostname.'
    }
    $c.Outputs.Runtime_connector_name = 'commondataserviceforapps'
    Assert ((Evaluate $actions.Choose_record_connector.expression $c) -ceq 'dataverse') 'Bare legacy Dataverse name changed across clouds.'
    $c.Outputs.Runtime_connector_name = 'sharepointonline'
    Assert ((Evaluate $actions.Choose_record_connector.expression $c) -ceq 'shared_sharepointonline') 'Bare legacy SharePoint name changed across clouds.'
}
Test-Case 'Public is the unchanged default choice and unimplemented sovereign clouds fail before generation' {
    $defaultParameters = @{} + $parameters
    $defaultParameters.Remove('Cloud')
    $defaultPackage = & $generator @defaultParameters
    $explicitPackage = & $generator @defaultParameters -Cloud Public
    Assert ($defaultPackage.targetCloud -ceq 'Public') 'Default cloud changed from Public.'
    Assert ((ConvertTo-Json -InputObject $defaultPackage.definition -Compress -Depth 100) -ceq
        (ConvertTo-Json -InputObject $explicitPackage.definition -Compress -Depth 100)) 'Default versus explicit Public definitions differ.'
    foreach ($unsupported in @('GCCHigh', 'DoD', 'China', 'AzureUSGovernment')) {
        $caught = $false
        try { $null = & $generator @defaultParameters -Cloud $unsupported }
        catch [Management.Automation.ParameterBindingException] { $caught = $true }
        Assert $caught 'Unimplemented cloud silently fell back to Public or GCC.'
    }
}

Test-Case 'Solution configuration uses ordinary parameter schema bindings and no fixed tenant/site or secure-I/O flags' {
    $solutionPackage = & $generator -Cloud $Cloud -UseSolutionEnvironmentVariables
    Assert ($solutionPackage.deployment.configurationMode -ceq 'SolutionEnvironmentVariables' -and
        $null -eq $solutionPackage.targetTenantId -and $null -eq $solutionPackage.deployment.reportSite) 'Solution mode retains a fixed target.'
    $settings = $solutionPackage.deployment.environmentVariables
    Assert ($settings.Count -eq 3) 'Expected tenant/site/folder definitions.'
    $configured = @{}
    Collect-Actions $solutionPackage.definition.actions 1 $configured
    Assert ($configured.Count -le 500 -and $maxDepth -le 8) 'Solution configuration exceeded native limits.'
    Assert-NoExplicitSecureData $solutionPackage.definition
    foreach ($setting in $settings) {
        $binding = $solutionPackage.definition.parameters[$setting.ParameterName]
        Assert ($binding.type -ceq 'String' -and $binding.metadata.schemaName -ceq $setting.SchemaName) 'Environment-variable parameter metadata is unsupported/inconsistent.'
        if ($setting.Required) { Assert ($binding.defaultValue -ceq '') 'Required tenant/site has a bound source value.' }
    }
    $first = $expressions.Count
    Collect-Expressions $solutionPackage.definition
    for ($index = $first; $index -lt $expressions.Count; $index++) { $null = Parse-Wdl $expressions[$index]; Assert ($expressions[$index].Length -le 8192) 'Configured expression too long.' }
    $c = Context
    foreach ($setting in $settings) { $c.Parameters[$setting.ParameterName] = $setting.DefaultValue }
    Assert (-not [bool](Evaluate $configured.Validate_solution_configuration.expression.equals[0] $c)) 'Unconfigured solution can run as if valid.'
    $c.Parameters[$settings[0].ParameterName] = '11111111-1111-4111-8111-111111111111'
    $c.Parameters[$settings[1].ParameterName] = 'https://contoso.sharepoint.com/sites/Reports'
    Assert ([bool](Evaluate $configured.Validate_solution_configuration.expression.equals[0] $c)) 'Ordinary valid import values rejected.'
    Assert ((Evaluate $configured.Compose_report_manifest.inputs.TenantId $c) -ceq $c.Parameters[$settings[0].ParameterName]) 'Manifest ignored the imported tenant setting.'
    Assert ((Evaluate $configured.Write_JSON_report.inputs.parameters.dataset $c) -ceq $c.Parameters[$settings[1].ParameterName]) 'SharePoint action ignored the imported site setting.'
    $c.Outputs.Compose_unique_report_prefix = 'flow-history-fixture'
    Assert ((Evaluate $configured.Read_JSON_report_back.inputs.parameters.path $c) -ceq '/Shared Documents/FlowRunHistory/flow-history-fixture.json') 'Read-back path ignored the imported folder setting.'
    $c.Parameters[$settings[0].ParameterName] = '00000000-0000-0000-0000-000000000000'
    Assert (-not [bool](Evaluate $configured.Validate_solution_configuration.expression.equals[0] $c)) 'Solution accepted an empty tenant sentinel.'
    $valid = @{} + $c.Parameters
    $valid[$settings[0].ParameterName] = '11111111-1111-4111-8111-111111111111'
    foreach ($case in @(
        @{ Index = 0; Value = '' }, @{ Index = 0; Value = 'not-a-guid' },
        @{ Index = 1; Value = '' }, @{ Index = 1; Value = 'http://contoso.sharepoint.com/sites/Reports' },
        @{ Index = 1; Value = 'https://user:password@contoso.sharepoint.com/sites/Reports' },
        @{ Index = 1; Value = 'https://contoso.sharepoint.com/sites/Reports?sig=secret' },
        @{ Index = 2; Value = '' }, @{ Index = 2; Value = 'relative/folder' },
        @{ Index = 2; Value = '/Shared Documents/../Other' }, @{ Index = 2; Value = '/Shared Documents/Reports/' }
    )) {
        $c.Parameters = @{} + $valid
        $c.Parameters[$settings[$case.Index].ParameterName] = $case.Value
        Assert (-not [bool](Evaluate $configured.Validate_solution_configuration.expression.equals[0] $c)) 'Invalid required solution configuration can produce an apparently valid run.'
    }
    Assert ($configured.Stop_unconfigured_solution.inputs.runStatus -ceq 'Failed') 'Missing solution configuration is not explicit.'
}

$failed = @($results | Where-Object { -not $_.Passed })
$report = @{
    Engine = $PSVersionTable.PSVersion.ToString(); Passed = $results.Count - $failed.Count; Failed = $failed.Count
    Cloud = $expectedCloud
    ActionCount = $actions.Count; MaxNesting = $maxDepth; ExpressionCount = $expressions.Count
    Scope = 'Offline structural and generated-expression fixtures; not a native runtime emulator or a live tenant test.'
    Tests = $results.ToArray()
}
if ($ResultsPath) { $report | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $ResultsPath -Encoding UTF8 }
Write-Host "PowerShell $($report.Engine), $($report.Cloud): $($report.Passed) passed, $($report.Failed) failed; $($report.ActionCount) actions, nesting $maxDepth."
if ($failed.Count -gt 0) { exit 1 }

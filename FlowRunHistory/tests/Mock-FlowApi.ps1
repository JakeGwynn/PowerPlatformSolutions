#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][int]$Port)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$listener = [Net.HttpListener]::new()
$origin = "http://127.0.0.1:$Port"
$listener.Prefixes.Add("$origin/")
$listener.Start()
$scenario = 'normal'
$requests = [System.Collections.Generic.List[object]]::new()
$attempts = @{}
$flowA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
$flowB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
$flowC = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
$rowId = '12345678-1234-4234-8234-123456789abc'
$lookupId = '99999999-9999-4999-8999-999999999999'
$itemGuid = '12121212-1212-4212-8212-121212121212'
$root = '/providers/Microsoft.ProcessSimple/environments/test-environment'

function Send-Response {
    param($Context, $Body, [int]$Code = 200, [hashtable]$Headers = @{}, [switch]$Raw,
        [string]$ContentType = 'application/json')
    $Context.Response.StatusCode = $Code
    foreach ($key in $Headers.Keys) { $Context.Response.Headers[$key] = $Headers[$key] }
    $Context.Response.ContentType = $ContentType
    if (-not $Raw) { $Body = ConvertTo-Json -InputObject $Body -Depth 80 -Compress }
    $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Body)
    $Context.Response.ContentLength64 = $bytes.Length
    try { $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length) }
    catch [Net.HttpListenerException] { } # A size-limit test deliberately disconnects before the body is written.
    finally { $Context.Response.Close() }
}

function New-Link {
    param([string]$Name)
    return @{ uri = "$origin/content/$Name`?sig=fixture-secret"; contentSize = 100 }
}

function New-Trigger {
    param([string]$Flow)
    $kind = 'dv'
    if ($Flow -eq $flowB -or $scenario -like 'sp-*') { $kind = 'sp' }
    if ($Flow -eq $flowC) { $kind = 'recurrence' }
    $trigger = @{
        name = 'When_row_changes'; status = 'Succeeded'
        inputsLink = New-Link "$kind-input"; outputsLink = New-Link "$kind-output"
    }
    if ($kind -eq 'sp') { $trigger.name = 'When_item_changes' }
    if ($kind -eq 'recurrence') { $trigger.name = 'Recurrence'; $trigger.Remove('inputsLink'); $trigger.Remove('outputsLink') }
    if ($scenario -eq 'secured') { $trigger.secureData = @{ properties = @('outputs') } }
    if ($scenario -eq 'missing-payload') { $trigger.Remove('outputsLink') }
    if ($scenario -eq 'blocked-host') { $trigger.outputsLink = @{ uri = 'https://example.invalid/leak?sig=fixture-secret' } }
    if ($scenario -eq 'failed-trigger') {
        $trigger.status = 'Failed'
        $trigger.error = @{ code = 'TriggerFailed'; message = 'Trigger envelope failure' }
    }
    return $trigger
}

function New-Action {
    param([string]$Name)
    $properties = @{
        status = 'Succeeded'; code = 'OK'
        inputsLink = New-Link "action-$Name-input"; outputsLink = New-Link "action-$Name-output"
    }
    if ($Name -in @('Scope', 'Inner', 'Write_Record')) {
        $properties.status = 'Failed'
        $properties.code = 'ActionFailed'
    }
    if ($Name -eq 'Loop') { $properties.iterationCount = 2 }
    if ($Name -eq 'Write_Record' -and $scenario -eq 'truncated-repetitions') { $properties.repetitionCount = 2 }
    if ($Name -eq 'Inner') {
        $properties.retryHistory = @(@{ code = 'BadGateway'; error = @{ code = 'RetryError'; message = 'A failed retry' } })
        if ($scenario -eq 'wrapped-retry') {
            $properties.retryHistory = @(@{ error = @{ error = @{ code = 'Wrapped'; message = 'Wrapped retry message' } } })
        }
    }
    return @{ name = $Name; properties = $properties }
}

function New-Run {
    param([string]$Flow, [string]$Name, [bool]$Expanded = $false)
    $time = '2026-11-07T12:00:00Z'
    $status = 'Failed'
    $code = 'WorkflowRunActionFailed'
    switch ($Name) {
        'run-success' { $time = '2026-11-10T00:00:00Z'; $status = 'Succeeded'; $code = 'OK' }
        'run-cancelled' { $time = '2026-11-12T00:00:00Z'; $status = 'Cancelled'; $code = 'Cancelled' }
        'run-before' { $time = '2026-11-06T23:59:59.9999999Z' }
        'run-upper' { $time = '2026-11-13T00:00:00Z' }
        'b-success' { $time = '2026-11-08T00:00:00Z'; $status = 'Succeeded'; $code = 'OK' }
        'b-terminated' { $time = '2026-11-09T00:00:00Z'; $status = 'Failed'; $code = 'Terminated' }
        'c-run' { $time = '2026-11-08T00:00:00Z'; $status = 'Succeeded'; $code = 'OK' }
    }
    if ($scenario -eq 'rolling-dates') {
        $time = [DateTimeOffset]::UtcNow.AddDays(-1).ToString('o')
        if ($Name -eq 'run-before') { $time = [DateTimeOffset]::UtcNow.AddDays(-10).ToString('o') }
        if ($Name -eq 'run-upper') { $time = [DateTimeOffset]::UtcNow.AddDays(1).ToString('o') }
    }
    $properties = @{
        startTime = $time; endTime = $time; status = $status; code = $code
        trigger = New-Trigger $Flow
    }
    if ($Expanded) {
        $properties.actions = @{}
        foreach ($action in @('Scope', 'Loop', 'Write_Record')) {
            $properties.actions[$action] = (New-Action $action).properties
        }
    }
    return @{ name = $Name; id = "$root/flows/$Flow/runs/$Name"; properties = $properties }
}

function Get-RunNames {
    param([string]$Flow)
    if ($scenario -eq 'no-runs') { return }
    if ($Flow -eq $flowA) { return @('run-failed', 'run-success', 'run-cancelled', 'run-before', 'run-upper') }
    if ($Flow -eq $flowB) { return @('b-failed', 'b-success', 'b-terminated') }
    return @('c-run')
}

function New-Flow {
    param([string]$Id)
    $api = 'shared_commondataserviceforapps'
    $operation = 'SubscribeWebhookTrigger'
    $triggerName = 'When_row_changes'
    if ($Id -eq $flowB -or $scenario -like 'sp-*') {
        $api = 'shared_sharepointonline'; $operation = 'GetOnUpdatedItems'; $triggerName = 'When_item_changes'
    }
    $hostInfo = @{ apiId = "/providers/Microsoft.PowerApps/apis/$api"; operationId = $operation }
    $actions = @{
        Scope = @{ type = 'Scope'; actions = @{ Inner = @{ type = 'OpenApiConnection' } } }
        Loop = @{ type = 'Foreach'; actions = @{ Write_Record = @{ type = 'OpenApiConnection' } } }
    }
    if ($scenario -eq 'branches') {
        $actions.Condition = @{
            type = 'If'; actions = @{ True_Action = @{ type = 'Compose' } }
            else = @{ actions = @{ False_Action = @{ type = 'Compose' } } }
        }
        $actions.Switch = @{
            type = 'Switch'
            cases = @{ Case_One = @{ actions = @{ Case_Action = @{ type = 'Compose' } } } }
            default = @{ actions = @{ Default_Action = @{ type = 'Compose' } } }
        }
        $actions.Loop.actions.Nested_Loop = @{
            type = 'Foreach'; actions = @{ Nested_Write = @{ type = 'Compose' } }
        }
    }
    if ($scenario -eq 'historical-loop') {
        $actions.Loop.actions.Remove('Write_Record')
        $actions.Write_Record = @{ type = 'Compose' }
    }
    return @{
        name = $Id
        properties = @{
            displayName = "Fixture flow $Id"; isSolutionAware = ($Id -eq $flowC)
            connectionReferences = @{ fixture = @{ id = "/providers/Microsoft.PowerApps/apis/$api" } }
            definition = @{
                triggers = @{ $triggerName = @{ type = 'OpenApiConnectionWebhook'; inputs = @{ host = $hostInfo } } }
                actions = $actions
            }
        }
    }
}

function Send-Page {
    param($Context, [object[]]$Items, [int]$Size = 2)
    $offset = 0
    if ($Context.Request.QueryString['page']) { $offset = [int]$Context.Request.QueryString['page'] }
    $pageItems = @($Items | Select-Object -Skip $offset -First $Size)
    $body = @{ value = $pageItems }
    if ($offset + $Size -lt $Items.Count) {
        $query = $Context.Request.QueryString
        $pairs = @(
            foreach ($key in $query.AllKeys) {
                if ($key -ne 'page') { [uri]::EscapeDataString($key) + '=' + [uri]::EscapeDataString($query[$key]) }
            }
        )
        $next = "$origin$($Context.Request.Url.AbsolutePath)?$($pairs -join '&')&page=$($offset + $Size)"
        if ($offset -eq 0) { $body.nextLink = $next }
        else { $body.'@odata.nextLink' = $next }
    }
    if ($scenario -eq 'evil-paging') { $body.nextLink = 'https://example.invalid/leak?sig=fixture-secret' }
    if ($scenario -eq 'cycle-paging') { $body.nextLink = $Context.Request.Url.AbsoluteUri }
    if ($scenario -eq 'relative-paging' -and $body.ContainsKey('nextLink')) {
        $body.nextLink = ([uri]$body.nextLink).PathAndQuery
    }
    Send-Response $Context $body
}

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $path = $context.Request.Url.AbsolutePath
        if ($path -eq '/_ready') { Send-Response $context @{ ready = $true }; continue }
        if ($path -eq '/_stop') { Send-Response $context @{ stopped = $true }; break }
        if ($path -eq '/_control') {
            $reader = [IO.StreamReader]::new($context.Request.InputStream)
            try { $control = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
            $scenario = $control.scenario
            $requests.Clear(); $attempts.Clear()
            Send-Response $context @{ scenario = $scenario }
            continue
        }
        if ($path -eq '/_requests') { Send-Response $context @{ value = $requests.ToArray() }; continue }
        $authorization = [string]$context.Request.Headers['Authorization']
        $requests.Add([pscustomobject]@{
            Method = $context.Request.HttpMethod; Path = $path; Query = $context.Request.Url.Query
            HasAuthorization = [bool]$authorization; Authorization = $authorization
        })
        if (-not $attempts.ContainsKey($path)) { $attempts[$path] = 0 }
        $attempts[$path]++
        if ($context.Request.HttpMethod -ne 'GET') {
            Send-Response $context @{ error = @{ message = 'Only GET is allowed' } } 405; continue
        }
        if ($path -like '/content/*') {
            if ($authorization) { Send-Response $context @{ error = @{ message = 'Bearer token leaked to a content endpoint' } } 400; continue }
            if ($scenario -eq 'expired-payload') { Send-Response $context @{ error = 'expired' } 403; continue }
            if ($scenario -eq 'deleted-payload') { Send-Response $context @{ error = 'deleted' } 410; continue }
            if ($scenario -eq 'redirect-payload') {
                Send-Response $context @{} 302 @{ Location = "$origin/leaked" }; continue
            }
            if ($scenario -eq 'invalid-payload') { Send-Response $context '{broken' 200 @{} -Raw; continue }
            if ($scenario -eq 'empty-json') { Send-Response $context '' 200 @{} -Raw; continue }
            if ($scenario -eq 'empty-text') { Send-Response $context '' 200 @{} -Raw -ContentType 'text/plain'; continue }
            if ($scenario -eq 'binary-payload') {
                $bytes = [byte[]]@(0, 255, 1, 128)
                $context.Response.ContentType = 'application/octet-stream'
                $context.Response.ContentLength64 = $bytes.Length
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $context.Response.Close()
                continue
            }
            if ($scenario -eq 'oversize-payload') {
                Send-Response $context ('x' * (2 * 1024 * 1024)) 200 @{} -Raw -ContentType 'text/plain'; continue
            }
            $name = $path.Substring('/content/'.Length)
            if ($name -eq 'dv-input') {
                $hostInfo = @{
                    apiId = '/providers/Microsoft.PowerApps/apis/shared_commondataserviceforapps'
                    operationId = 'SubscribeWebhookTrigger'
                }
                if ($scenario -eq 'unsupported-dv') { $hostInfo.operationId = 'PerformUnboundAction' }
                if ($scenario -eq 'current-binding') {
                    $hostInfo.Remove('apiId'); $hostInfo.connectionReferenceName = 'fixture'
                }
                $parameters = @{ 'subscriptionRequest/entityname' = 'accounts' }
                if ($scenario -eq 'custom-primary-key') { $parameters['subscriptionRequest/entityname'] = 'new_widgets' }
                if ($scenario -eq 'current-definition-only') { $hostInfo = $null }
                if ($scenario -eq 'odata-table-context') { $parameters = @{} }
                Send-Response $context @{ host = $hostInfo; parameters = $parameters }; continue
            }
            if ($name -eq 'dv-output') {
                $body = @{ accountid = $rowId; _primarycontactid_value = $lookupId; arbitraryid = $lookupId; SdkMessage = 'Update' }
                switch ($scenario) {
                    'dv-odata' { $body.'@odata.id' = "https://example.crm.dynamics.com/api/data/v9.2/accounts($rowId)" }
                    'dv-editlink' { $body.'@odata.editLink' = "accounts($rowId)" }
                    'dv-context' { $body.PrimaryEntityName = 'account'; $body.PrimaryEntityId = $rowId }
                    'dv-conflict' { $body.'@odata.id' = "accounts($lookupId)" }
                    'dv-value-column' { $body.value = @('a custom', 'array column') }
                    'odata-table-context' { $body.'@odata.context' = 'https://example.crm.dynamics.com/api/data/v9.2/$metadata#accounts/$entity' }
                    'custom-primary-key' { $body.Remove('accountid'); $body.new_unusualkey = $rowId }
                    'dv-lookup-only' { $body.Remove('accountid') }
                    'bad-primary-key' { $body.accountid = 'not-a-guid' }
                    'batch' { $body = @{ value = @($body, $body) } }
                    'failed-trigger' { $body = @{ error = @{ code = 'TriggerOutputError'; message = 'Detailed trigger output failure' } } }
                }
                Send-Response $context @{
                    headers = @{ Authorization = 'Bearer fixture-sensitive-value'; Location = "$origin/content/private?sig=fixture-secret" }
                    body = $body
                }
                continue
            }
            if ($name -eq 'sp-input') {
                Send-Response $context @{
                    host = @{ apiId = '/providers/Microsoft.PowerApps/apis/shared_sharepointonline'; operationId = 'GetOnUpdatedItems' }
                    parameters = @{ dataset = 'https://contoso.sharepoint.com/sites/fixture'; table = 'list-fixture' }
                }
                continue
            }
            if ($name -eq 'sp-output') {
                $body = @{ ID = 42; UniqueId = $itemGuid; '{Identifier}' = 'folder/file.txt'; Lookup = @{ Id = 99 } }
                if ($scenario -eq 'sp-lookup-only') { $body.Remove('ID') }
                if ($scenario -eq 'sp-batch') { $body = @{ value = @($body, $body) } }
                if ($scenario -eq 'sp-single-batch') { $body = @{ value = @($body) } }
                Send-Response $context @{ body = $body }; continue
            }
            if ($name -match '^action-(.+)-output$') {
                if ($scenario -eq 'structured-message') {
                    Send-Response $context @{
                        body = @{ error = @{ code = 'ConnectorError'; message = @{ lang = 'en-US'; value = 'Structured connector message' } } }
                    }
                    continue
                }
                Send-Response $context @{
                    statusCode = 400
                    body = @{ error = @{ code = 'DetailedActionError'; message = "Detailed action output: $($Matches[1])" } }
                }
                continue
            }
            if ($name -match '^repetition-(.+)-output$') {
                Send-Response $context @{
                    body = @{ error = @{ code = 'IterationError'; message = "Detailed repetition output: $($Matches[1])" } }
                }
                continue
            }
            if ($name -eq 'action-Loop-input') {
                Send-Response $context '"fixture scalar"' 200 @{} -Raw; continue
            }
            Send-Response $context @{ value = 'fixture payload'; nested = @{ id = $lookupId } }
            continue
        }
        if (-not $authorization) { Send-Response $context @{ error = 'Missing bearer' } 401; continue }
        if ($scenario -eq 'unauthorized') { Send-Response $context @{ error = 'Unauthorized' } 401; continue }
        if ($scenario -eq 'forbidden') { Send-Response $context @{ error = 'Forbidden' } 403; continue }
        if ($scenario -eq 'redirect-service') {
            Send-Response $context @{} 302 @{ Location = "$origin/leaked" }; continue
        }
        if ($path -eq '/api/data/v9.2/EntityDefinitions') {
            $attribute = 'accountid'
            if ($context.Request.QueryString['$filter'] -like '*new_widgets*') { $attribute = 'new_unusualkey' }
            Send-Response $context @{
                value = @(@{ LogicalName = 'account'; EntitySetName = 'accounts'; PrimaryIdAttribute = $attribute })
            }
            continue
        }
        if ($path -match '/runs$') {
            if ($scenario -in @('throttled', 'retry-date', 'server-error', 'retry-budget', 'always-throttled')) {
                if ($attempts[$path] -eq 1 -or $scenario -in @('always-throttled', 'retry-budget')) {
                    $headers = @{ 'Retry-After' = '0' }
                    if ($scenario -eq 'retry-date') { $headers['Retry-After'] = [DateTimeOffset]::UtcNow.AddSeconds(1).ToString('r') }
                    if ($scenario -eq 'retry-budget') { $headers['Retry-After'] = '60' }
                    $code = 429
                    if ($scenario -eq 'server-error') { $code = 503 }
                    Send-Response $context @{ error = 'Transient' } $code $headers
                    continue
                }
            }
            if ($scenario -eq 'invalid-json') { Send-Response $context '{invalid' 200 @{} -Raw; continue }
            if ($scenario -eq 'invalid-collection') { Send-Response $context @{ unexpected = @() }; continue }
            if ($scenario -eq 'invalid-value-shape') { Send-Response $context @{ value = @{ name = 'not-an-array' } }; continue }
        }
        if ($path -match '/flows$') {
            if ($scenario -eq 'no-flows') { Send-Response $context @{ value = @() }; continue }
            $ids = @($flowA, $flowB, $flowC)
            if ($path -notmatch '/scopes/admin/') {
                $ids = @($flowA, $flowB)
                if ($context.Request.QueryString['$filter'] -eq "search('team')") { $ids = @($flowA, $flowC) }
            }
            $items = @($ids | ForEach-Object { New-Flow $_ })
            Send-Page $context $items 1
            continue
        }
        if ($path -match '/flows/([^/]+)$') {
            if ($scenario -eq 'definition-denied') { Send-Response $context @{ error = 'Forbidden' } 403; continue }
            Send-Response $context (New-Flow $Matches[1]); continue
        }
        if ($path -match '/flows/([^/]+)/runs$') {
            $flow = $Matches[1]
            $items = @(Get-RunNames $flow | ForEach-Object { New-Run $flow $_ })
            Send-Page $context $items
            continue
        }
        if ($path -match '/flows/([^/]+)/runs/([^/]+)$') {
            $flow = $Matches[1]; $run = $Matches[2]
            if ($scenario -eq 'detail-denied') { Send-Response $context @{ error = 'Forbidden' } 403; continue }
            if ($run -notin @(Get-RunNames $flow)) { Send-Response $context @{ error = 'Not found' } 404; continue }
            Send-Response $context (New-Run $flow $run ([bool]$context.Request.QueryString['$expand']))
            continue
        }
        if ($path -match '/runs/[^/]+/actions$') {
            if ($scenario -eq 'actions-unsupported') { Send-Response $context @{ error = 'Not supported' } 404; continue }
            $items = @('Scope', 'Loop', 'Write_Record' | ForEach-Object { New-Action $_ })
            if ($scenario -eq 'historical-action') { $items += New-Action 'Old_Action' }
            Send-Page $context $items
            continue
        }
        if ($path -match '/actions/([^/]+)/(repetitions|scopeRepetitions)$') {
            $name = $Matches[1]; $kind = $Matches[2]
            if ($scenario -eq 'repetitions-unsupported') { Send-Response $context @{ error = 'Not supported' } 404; continue }
            if (($kind -eq 'repetitions' -and $name -notin @('Write_Record', 'Nested_Loop', 'Nested_Write', 'Old_Action')) -or
                ($kind -eq 'scopeRepetitions' -and $name -notin @('Loop', 'Nested_Loop'))) {
                Send-Response $context @{ value = @() }
                continue
            }
            $items = @(
                for ($i = 0; $i -lt 2; $i++) {
                    $repetitionName = '{0:D6}' -f $i
                    $status = 'Succeeded'
                    if ($i -eq 1) { $status = 'Failed' }
                    @{
                        name = $repetitionName
                        properties = @{
                            status = $status; code = $(if ($i -eq 1) { 'ActionFailed' } else { 'OK' })
                            repetitionIndexes = @(@{ scopeName = 'Outer'; itemIndex = 0 }, @{ scopeName = 'Loop'; itemIndex = $i })
                            inputsLink = New-Link "repetition-$repetitionName-input"
                            outputsLink = New-Link "repetition-$repetitionName-output"
                        }
                    }
                }
            )
            if ($scenario -eq 'truncated-repetitions') { $items = @($items[0]) }
            Send-Page $context $items 1
            continue
        }
        if ($path -match '/actions/([^/]+)$') {
            Send-Response $context (New-Action $Matches[1]); continue
        }
        Send-Response $context @{ error = @{ message = 'Unrecognized fixture route' } } 404
    }
}
finally { $listener.Close() }

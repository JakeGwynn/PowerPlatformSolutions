#Requires -Version 5.1
[CmdletBinding()]
param([string]$ResultsPath, [string]$TestName)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..\Get-FlowRunHistory.ps1'
$serverPath = Join-Path $PSScriptRoot 'Mock-FlowApi.ps1'
$results = [System.Collections.Generic.List[object]]::new()
$tenant = '11111111-1111-4111-8111-111111111111'
$otherTenant = '22222222-2222-4222-8222-222222222222'
$flowA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
$flowB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
$rowId = '12345678-1234-4234-8234-123456789abc'
$itemGuid = '12121212-1212-4212-8212-121212121212'
$originalModulePath = $env:PSModulePath
$job = $null
$timer = [Diagnostics.Stopwatch]::StartNew()
$exportRoot = Join-Path ([IO.Path]::GetTempPath()) ('flow-history-exports-' + [guid]::NewGuid().ToString('N'))
if ([IO.Directory]::Exists($exportRoot)) { throw 'The private export test directory already exists.' }
$null = [IO.Directory]::CreateDirectory($exportRoot)
$exportText = 'First, "quoted"' + "`r`n" + 'caf' + [char]0xE9 + ' ' + [char]0x6771 + [char]0x4EAC + ' ' + [char]::ConvertFromUtf32(0x1F680)

function Assert-Equal {
    param($Actual, $Expected, [string]$Message = 'Values differ')
    if ($Actual -cne $Expected) { throw "$Message (expected '$Expected', got '$Actual')" }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    $caught = $false
    try { & $Action | Out-Null }
    catch {
        $caught = $true
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "Expected /$Pattern/, got: $($_.Exception.Message)"
        }
    }
    if (-not $caught) { throw "Expected an exception matching /$Pattern/" }
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Action)
    if ($TestName -and $Name -notmatch $TestName) { return }
    $testTimer = [Diagnostics.Stopwatch]::StartNew()
    try {
        & $Action
        $results.Add([pscustomobject]@{ Name = $Name; Passed = $true; Error = $null; Seconds = $testTimer.Elapsed.TotalSeconds })
        Write-Host "PASS $Name"
    }
    catch {
        $results.Add([pscustomobject]@{ Name = $Name; Passed = $false; Error = $_.Exception.Message; Seconds = $testTimer.Elapsed.TotalSeconds })
        Write-Host "FAIL $Name : $($_.Exception.Message)"
        Write-Host $_.ScriptStackTrace
    }
}

function New-TestToken {
    param([string]$Tenant = $tenant, [string]$Audience = 'https://service.flow.microsoft.com/',
        [long]$Expiry = ([DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds()),
        [switch]$AppOnly, [long]$NotBefore = 0)
    $claims = @{ tid = $Tenant; aud = $Audience; exp = $Expiry; nbf = $NotBefore; scp = 'Flows.Read.All'; idtyp = 'user' }
    if ($AppOnly) { $claims.Remove('scp'); $claims.idtyp = 'app' }
    $json = ConvertTo-Json -InputObject $claims -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    return "e30.$encoded.fixture-not-a-real-credential"
}

function Set-Scenario {
    param([string]$Name = 'normal')
    $null = Invoke-RestMethod -Uri "$base/_control" -Method Post -Body (@{ scenario = $Name } | ConvertTo-Json -Compress) -ContentType 'application/json'
}

function Get-Requests {
    return @((Invoke-RestMethod -Uri "$base/_requests").value)
}

function Invoke-History {
    param([hashtable]$Options = @{}, [switch]$WithoutToken)
    $arguments = @{} + $defaults
    if ($WithoutToken) { $arguments.Remove('AccessToken') }
    foreach ($key in $Options.Keys) { $arguments[$key] = $Options[$key] }
    & $scriptPath @arguments -WarningAction SilentlyContinue
}

function New-AuthFixture {
    param([string]$ContextTenant = $tenant, [string]$AccountType = 'User', [string]$Cloud = 'AzureCloud')
    return @{
        Token = New-TestToken
        Context = [pscustomobject]@{
            Tenant = @{ Id = $ContextTenant }; Account = @{ Type = $AccountType }; Environment = @{ Name = $Cloud }
        }
        Calls = [System.Collections.Generic.List[object]]::new()
    }
}

function Get-TestExportPath {
    param([string]$Extension)
    return Join-Path $exportRoot ([guid]::NewGuid().ToString('N') + '.' + $Extension)
}

function Assert-NoStagingFiles {
    Assert-Equal @([IO.Directory]::GetFiles($exportRoot, '.flow-history-*.partial')).Count 0 'An unpublished private staging file was left behind.'
}

try {
    $portProbe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $portProbe.Start()
    $port = $portProbe.LocalEndpoint.Port
    $portProbe.Stop()
    $base = "http://127.0.0.1:$port"
    $job = Start-Job -FilePath $serverPath -ArgumentList $port
    $ready = $false
    for ($i = 0; $i -lt 100; $i++) {
        try { $ready = [bool](Invoke-RestMethod -Uri "$base/_ready" -TimeoutSec 1).ready }
        catch {
            if ($job.State -eq 'Failed') { throw "Mock HTTP server failed: $(Receive-Job $job 2>&1 | Out-String)" }
        }
        if ($ready) { break }
        Start-Sleep -Milliseconds 100
    }
    if (-not $ready) { throw 'Mock HTTP server did not become ready.' }
    $defaults = @{
        TenantId = $tenant; EnvironmentName = 'test-environment'; AccessToken = New-TestToken
        TestApiBaseUri = $base; MaxRetries = 0; RequestTimeoutSeconds = 5
    }

    Invoke-Test 'Public comment-based help exposes the synopsis, switches, and complete invocation examples' {
        $help = Get-Help $scriptPath -Full
        Assert-True ([string]$help.Synopsis -match '^Reads Power Automate cloud-flow run history') 'Comment-based help was not discovered.'
        Assert-Equal @($help.examples.example).Count 6
        $examples = $help.examples.example | Out-String -Width 4096
        Assert-True ($examples -match '-Status Failed -LastDays 7 -Errors') 'The full example invocation was lost.'
        Assert-True ('CallingRecordId' -in $help.parameters.parameter.name) 'Public projection help is missing.'
        Assert-True ('CsvPath' -in $help.parameters.parameter.name -and 'JsonPath' -in $help.parameters.parameter.name) 'Export help is missing.'
    }

    Invoke-Test 'Single flow summary, paged runs, no detail requests' {
        Set-Scenario
        $items = @(Invoke-History @{ FlowId = $flowA })
        Assert-Equal $items.Count 5
        Assert-Equal @($items | Where-Object Status -eq 'Cancelled').Count 1
        Assert-True (-not ($items[0].PSObject.Properties.Name -contains 'Actions')) 'Summary downloaded full details.'
        $requests = @(Get-Requests)
        Assert-Equal $requests.Count 3
        Assert-True (@($requests | Where-Object Path -match '/actions|/content').Count -eq 0) 'Summary fetched payloads.'
    }
    Invoke-Test 'Multiple flow IDs are deduplicated' {
        Set-Scenario
        $items = @(Invoke-History @{ FlowId = @($flowA, $flowB, $flowA) })
        Assert-Equal $items.Count 8
        Assert-Equal @($items | Select-Object -ExpandProperty FlowId -Unique).Count 2
    }
    Invoke-Test 'Visible discovery unions personal/shared and includes solutions, paging every collection' {
        Set-Scenario
        $items = @(Invoke-History)
        Assert-Equal $items.Count 9
        Assert-Equal @($items | Select-Object -ExpandProperty FlowId -Unique).Count 3
        $flowRequests = @(Get-Requests | Where-Object Path -match '/flows$')
        Assert-Equal $flowRequests.Count 4
        Assert-True (@($flowRequests | Where-Object Query -notmatch 'include=includeSolutionCloudFlows').Count -eq 0) 'Solution flow inclusion missing.'
    }
    Invoke-Test 'Admin discovery uses v2 and admin run listing, including solution flows' {
        Set-Scenario
        $items = @(Invoke-History @{ AllFlows = $true; AsAdmin = $true })
        Assert-Equal $items.Count 9
        $requests = @(Get-Requests)
        Assert-True (@($requests | Where-Object Path -notmatch '/scopes/admin/').Count -eq 0) 'Admin discovery used owner route.'
        Assert-Equal @($requests | Where-Object Path -match '/v2/flows$').Count 3
    }
    Invoke-Test 'Single run uses the direct endpoint, not history listing' {
        Set-Scenario
        $items = @(Invoke-History @{ FlowId = $flowA; RunId = 'run-failed' })
        Assert-Equal $items.Count 1
        Assert-Equal $items[0].RunId 'run-failed'
        Assert-Equal @(Get-Requests).Count 1
    }
    Invoke-Test 'Multiple run names match across multiple selected flows without duplicates' {
        Set-Scenario
        $items = @(Invoke-History @{ FlowId = @($flowA, $flowB); RunId = @('run-failed', 'b-failed', 'run-failed') })
        Assert-Equal $items.Count 2
        Assert-Equal @(Get-Requests).Count 4
    }
    Invoke-Test 'Run selection without flow IDs searches visible flows' {
        Set-Scenario
        $items = @(Invoke-History @{ RunId = 'b-failed' })
        Assert-Equal $items.Count 1
        Assert-Equal $items[0].FlowId $flowB
    }
    Invoke-Test 'Admin run ID selection uses admin history and preserves filtering semantics' {
        Set-Scenario
        $items = @(Invoke-History @{
            FlowId = $flowA; RunId = @('run-failed', 'run-success'); AsAdmin = $true
            Status = 'Failed'; From = '2026-11-07T00:00:00Z'; To = '2026-11-13T00:00:00Z'
        })
        Assert-Equal $items.Count 1
        Assert-Equal $items[0].RunId 'run-failed'
        Assert-True (@(Get-Requests | Where-Object Query -match '\$filter').Count -eq 0) 'Run selection was prematurely filtered.'
    }
    Invoke-Test 'Failed runs for multiple flows in an explicit UTC interval' {
        Set-Scenario
        $items = @(Invoke-History @{
            FlowId = @($flowA, $flowB); Status = 'Failed'
            From = '2026-11-07T00:00:00Z'; To = '2026-11-13T00:00:00Z'
        })
        Assert-Equal $items.Count 3
        Assert-True (@($items | Where-Object Status -ne 'Failed').Count -eq 0) 'Status filtering failed.'
        $query = [uri]::UnescapeDataString(@(Get-Requests)[0].Query)
        Assert-True ($query -match "status eq 'Failed'" -and $query -match 'startTime ge' -and $query -match 'startTime lt') 'Server filter missing.'
    }
    Invoke-Test 'UTC lower inclusive / upper exclusive, fractional boundary and explicit offset' {
        Set-Scenario
        $items = @(Invoke-History @{
            FlowId = $flowA; From = '2026-11-06T19:00:00-05:00'; To = '2026-11-13T00:00:00Z'
        })
        Assert-Equal $items.Count 3
        Assert-True ('run-before' -notin $items.RunId -and 'run-upper' -notin $items.RunId) 'UTC boundary inclusion is incorrect.'
    }
    Invoke-Test 'Multiple statuses are filtered locally without relabeling cancellation' {
        Set-Scenario
        $items = @(Invoke-History @{ FlowId = $flowA; Status = @('Failed', 'Cancelled') })
        Assert-Equal $items.Count 4
        Assert-Equal @($items | Where-Object Status -eq 'Cancelled').Count 1
    }
    Invoke-Test 'Terminated run code remains the actual Failed status' {
        Set-Scenario
        $items = @(Invoke-History @{ FlowId = $flowB; Status = 'Terminated' })
        Assert-Equal $items.Count 1
        Assert-Equal $items[0].RunId 'b-terminated'
        Assert-Equal $items[0].Status 'Failed'
    }
    Invoke-Test 'Rolling LastDays excludes old and future runs' {
        Set-Scenario 'rolling-dates'
        $items = @(Invoke-History @{ FlowId = $flowA; LastDays = 7 })
        Assert-Equal $items.Count 3
    }
    Invoke-Test 'A selected but filtered-out run is not reported missing' {
        Set-Scenario
        $items = @(Invoke-History @{ FlowId = $flowA; RunId = 'run-success'; Status = 'Failed' })
        Assert-Equal $items.Count 0
    }
    Invoke-Test 'No matching runs, no retained history, and no flows return empty output' {
        Set-Scenario
        Assert-Equal @(Invoke-History @{ FlowId = $flowA; Status = 'Suspended' }).Count 0
        Set-Scenario 'no-runs'
        Assert-Equal @(Invoke-History @{ FlowId = $flowA }).Count 0
        Set-Scenario 'no-flows'
        Assert-Equal @(Invoke-History).Count 0
    }
    Invoke-Test 'A nonexistent selected run is an explicit error, not empty success' {
        Set-Scenario
        Assert-Throws { Invoke-History @{ FlowId = $flowA; RunId = 'not-retained' } } 'not found.*retention'
        Assert-Equal @(Get-Requests).Count 1
    }
    Invoke-Test 'All includes nested actions, paged actions, paged repetitions, and both nested indexes' {
        Set-Scenario
        $item = @(Invoke-History @{ FlowId = $flowA; RunId = 'run-failed'; All = $true })[0]
        Assert-Equal $item.Actions.Count 4
        $inner = @($item.Actions | Where-Object Name -eq 'Inner')[0]
        Assert-Equal $inner.DefinitionPath 'Scope/Inner'
        $write = @($item.Actions | Where-Object Name -eq 'Write_Record')[0]
        Assert-Equal $write.Repetitions.Items.Count 2
        Assert-Equal $write.Repetitions.Items[1].RepetitionIndexes.Count 2
        Assert-Equal $write.Repetitions.Items[1].RepetitionIndexes[1].itemIndex 1
        $loop = @($item.Actions | Where-Object Name -eq 'Loop')[0]
        Assert-Equal $loop.ScopeRepetitions.Items.Count 2
        Assert-Equal $loop.Detail.Inputs.Content 'fixture scalar'
        Assert-Equal $item.Trigger.Outputs.Availability 'Available'
        Assert-Equal $item.DetailCoverage 'AvailableServiceData'
        Assert-Equal $item.FlowDisplayName "Fixture flow $flowA"
    }
    Invoke-Test 'Errors retrieves specific action/repetition/trigger/retry messages, not just the run envelope' {
        Set-Scenario 'failed-trigger'
        $item = @(Invoke-History @{ FlowId = $flowA; RunId = 'run-failed'; Errors = $true })[0]
        Assert-True (@($item.Errors | Where-Object Message -eq 'Detailed action output: Inner').Count -eq 1) 'Nested action output error missing.'
        Assert-True (@($item.Errors | Where-Object Message -eq 'Detailed repetition output: 000001').Count -eq 2) 'Failed repetition errors missing.'
        Assert-True (@($item.Errors | Where-Object Message -eq 'A failed retry').Count -eq 1) 'Retry error missing.'
        Assert-True (@($item.Errors | Where-Object Message -eq 'Detailed trigger output failure').Count -eq 1) 'Trigger output error missing.'
        Assert-True (@(Get-Requests | Where-Object Path -match '-input$').Count -eq 0) 'Errors unnecessarily fetched inputs.'
        Assert-Equal $item.Status 'Failed'
    }
    Invoke-Test 'Wrapped retry errors and structured connector error messages expose the actual message' {
        Set-Scenario 'wrapped-retry'
        $item = @(Invoke-History @{ FlowId = $flowA; RunId = 'run-failed'; Errors = $true })[0]
        Assert-True (@($item.Errors | Where-Object Message -eq 'Wrapped retry message').Count -eq 1) 'Wrapped retry message was hidden.'
        Set-Scenario 'structured-message'
        $item = @(Invoke-History @{ FlowId = $flowA; RunId = 'run-failed'; Errors = $true })[0]
        Assert-True (@($item.Errors | Where-Object Message -eq 'Structured connector message').Count -gt 0) 'Structured connector error message missing.'
    }
    Invoke-Test 'If/else, switch cases/default, and nested loops are discovered; historical actions are not dropped' {
        Set-Scenario 'branches'
        $item = @(Invoke-History @{ FlowId = $flowA; RunId = 'run-failed'; All = $true })[0]
        foreach ($name in @('True_Action', 'False_Action', 'Case_Action', 'Default_Action', 'Nested_Loop', 'Nested_Write')) {
            Assert-True ($name -in $item.Actions.Name) "Nested/branched action $name was omitted."
        }
        $nested = @($item.Actions | Where-Object Name -eq 'Nested_Write')[0]
        Assert-Equal $nested.DefinitionPath 'Loop/Nested_Loop/Nested_Write'
        Assert-Equal $nested.Repetitions.Items.Count 2
        Set-Scenario 'historical-action'
        $item = @(Invoke-History @{ FlowId = $flowA; RunId = 'run-failed'; All = $true })[0]
        Assert-True ('Old_Action' -in $item.Actions.Name) 'An action absent from the current definition was lost.'
        Assert-Equal @($item.Actions | Where-Object Name -eq 'Old_Action')[0].Repetitions.Items.Count 2
    }
    Invoke-Test 'Historical repetitions are queried even when the current definition moved the action out of a loop' {
        Set-Scenario 'historical-loop'
        $item = @(Invoke-History @{ FlowId = $flowA; RunId = 'run-failed'; All = $true })[0]
        $write = @($item.Actions | Where-Object Name -eq 'Write_Record')[0]
        Assert-Equal $write.DefinitionPath 'Write_Record'
        Assert-Equal $write.Repetitions.Items.Count 2
        Assert-Equal $write.Repetitions.Items[1].RepetitionIndexes.Count 2
    }
    Invoke-Test 'An advertised repetition count larger than the returned collection is reported incomplete' {
        Set-Scenario 'truncated-repetitions'
        $item = @(Invoke-History @{ FlowId = $flowA; RunId = 'run-failed'; All = $true })[0]
        Assert-Equal $item.DetailCoverage 'Partial'
        Assert-True (@($item.Issues | Where-Object State -eq 'CountMismatch').Count -eq 2) 'Advertised repetitions were silently omitted.'
    }
    Invoke-Test 'Dataverse actual primary key is selected, never arbitrary/lookup GUIDs' {
        Set-Scenario
        $item = @(Invoke-History @{
            FlowId = $flowA; RunId = 'run-failed'; CallingRecordId = $true
            DataversePrimaryKey = @{ accounts = 'accountid' }
        })[0]
        Assert-Equal $item.CallingRecord.RecordId $rowId
        Assert-Equal $item.CallingRecord.PrimaryKey 'accountid'
        Assert-True (-not ($item.PSObject.Properties.Name -contains 'StartTime')) 'Record projection contains run details.'
        $requests = @(Get-Requests)
        Assert-True (@($requests | Where-Object Path -match '/actions').Count -eq 0) 'Record extraction fetched actions.'
        Assert-True (@($requests | Where-Object Query -match 'expand').Count -eq 0) 'Record extraction expanded actions.'
    }
    Invoke-Test 'Canonical Dataverse OData row IDs and remote execution contexts need no map' {
        foreach ($scenarioName in @('dv-odata', 'dv-editlink', 'dv-context')) {
            Set-Scenario $scenarioName
            $items = @(Invoke-History @{ FlowId = $flowA; RunId = 'run-failed'; CallingRecordId = $true; IdOnly = $true })
            Assert-Equal $items.Count 1
            Assert-Equal $items[0] $rowId
        }
    }
    Invoke-Test 'Custom Dataverse primary key is not derived from table-name conventions' {
        Set-Scenario 'custom-primary-key'
        $item = @(Invoke-History @{
            FlowId = $flowA; RunId = 'run-failed'; CallingRecordId = $true
            DataversePrimaryKey = @{ new_widgets = 'new_unusualkey' }
        })[0]
        Assert-Equal $item.CallingRecord.RecordId $rowId
    }
    Invoke-Test 'Conflicting Dataverse canonical and primary-key identities are ambiguous' {
        Set-Scenario 'dv-conflict'
        $item = @(Invoke-History @{
            FlowId = $flowA; RunId = 'run-failed'; CallingRecordId = $true
            DataversePrimaryKey = @{ accounts = 'accountid' }
        })[0]
        Assert-Equal $item.CallingRecord.Availability 'Ambiguous'
        Assert-Equal $item.CallingRecord.RecordId $null
    }
    Invoke-Test 'Dataverse value columns are not confused with polling batches; OData context identifies the table' {
        foreach ($scenarioName in @('dv-value-column', 'odata-table-context')) {
            Set-Scenario $scenarioName
            $item = @(Invoke-History @{
                FlowId = $flowA; RunId = 'run-failed'; CallingRecordId = $true
                DataversePrimaryKey = @{ accounts = 'accountid' }
            })[0]
            Assert-Equal $item.CallingRecord.RecordId $rowId
        }
    }
    Invoke-Test 'Runtime connection references are resolved and labeled; current definition alone cannot prove history' {
        Set-Scenario 'current-binding'
        $item = @(Invoke-History @{
            FlowId = $flowA; RunId = 'run-failed'; CallingRecordId = $true
            DataversePrimaryKey = @{ accounts = 'accountid' }
        })[0]
        Assert-Equal $item.CallingRecord.RecordId $rowId
        Assert-Equal $item.CallingRecord.ConnectorEvidence 'RuntimeConnectionReferenceWithCurrentBinding'
        Set-Scenario 'current-definition-only'
        $item = @(Invoke-History @{
            FlowId = $flowA; RunId = 'run-failed'; CallingRecordId = $true
            DataversePrimaryKey = @{ accounts = 'accountid' }
        })[0]
        Assert-Equal $item.CallingRecord.Availability 'UnverifiedConnector'
        Assert-Equal $item.CallingRecord.RecordId $null
    }
    Invoke-Test 'Dataverse metadata uses a separate correct-audience token and explicit organization' {
        Set-Scenario
        $item = @(Invoke-History @{
            FlowId = $flowA; RunId = 'run-failed'; CallingRecordId = $true
            DataverseUrl = 'https://fixture.crm.dynamics.com/'
            DataverseAccessToken = (New-TestToken -Audience 'https://fixture.crm.dynamics.com/')
        })[0]
        Assert-Equal $item.CallingRecord.RecordId $rowId
        Assert-Equal $item.CallingRecord.Evidence 'DataverseMetadata'
        $metadataRequests = @(Get-Requests | Where-Object Path -match '/EntityDefinitions$')
        Assert-Equal $metadataRequests.Count 1
        Assert-True ($metadataRequests[0].Authorization -ne @(Get-Requests)[0].Authorization) 'Flow token was reused for Dataverse.'
    }
    Invoke-Test 'Lookup-only/invalid Dataverse keys and unsupported trigger operations are not guessed' {
        foreach ($scenarioName in @('dv-lookup-only', 'bad-primary-key', 'unsupported-dv')) {
            Set-Scenario $scenarioName
            $item = @(Invoke-History @{
                FlowId = $flowA; RunId = 'run-failed'; CallingRecordId = $true
                DataversePrimaryKey = @{ accounts = 'accountid' }
            })[0]
            Assert-Equal $item.CallingRecord.RecordId $null
            Assert-True ($item.CallingRecord.Availability -ne 'Available') 'Unverified row ID was accepted.'
        }
    }
    Invoke-Test 'A Dataverse batch is explicitly ambiguous' {
        Set-Scenario 'batch'
        $item = @(Invoke-History @{
            FlowId = $flowA; RunId = 'run-failed'; CallingRecordId = $true
            DataversePrimaryKey = @{ accounts = 'accountid' }
        })[0]
        Assert-Equal $item.CallingRecord.Availability 'Ambiguous'
        Assert-Equal $item.CallingRecord.RecordId $null
    }
    Invoke-Test 'SharePoint item/site/list/unique IDs are distinct from file and lookup identifiers' {
        Set-Scenario
        $item = @(Invoke-History @{ FlowId = $flowB; RunId = 'b-failed'; CallingRecordId = $true })[0]
        Assert-Equal $item.CallingRecord.RecordId '42'
        Assert-Equal $item.CallingRecord.ItemId '42'
        Assert-Equal $item.CallingRecord.UniqueId $itemGuid
        Assert-Equal $item.CallingRecord.SiteUrl 'https://contoso.sharepoint.com/sites/fixture'
        Assert-Equal $item.CallingRecord.ListId 'list-fixture'
        Assert-Equal @(Invoke-History @{ FlowId = $flowB; RunId = 'b-failed'; CallingRecordId = $true; IdOnly = $true })[0] '42'
    }
    Invoke-Test 'SharePoint batches and lookup-only payloads do not invent an item ID' {
        foreach ($scenarioName in @('sp-batch', 'sp-lookup-only')) {
            Set-Scenario $scenarioName
            $item = @(Invoke-History @{ FlowId = $flowB; RunId = 'b-failed'; CallingRecordId = $true })[0]
            Assert-Equal $item.CallingRecord.RecordId $null
            Assert-True ($item.CallingRecord.Availability -ne 'Available') 'Lookup/batch guessed as calling item.'
        }
        Set-Scenario 'sp-single-batch'
        Assert-Equal @(Invoke-History @{ FlowId = $flowB; RunId = 'b-failed'; CallingRecordId = $true; IdOnly = $true })[0] '42'
    }
    Invoke-Test 'RecordSource filters the identified connector and IdOnly returns no fabricated placeholder' {
        Set-Scenario
        $item = @(Invoke-History @{
            FlowId = $flowB; RunId = 'b-failed'; CallingRecordId = $true; RecordSource = 'Dataverse'
        })[0]
        Assert-Equal $item.CallingRecord.Availability 'Excluded'
        Assert-Equal @(Invoke-History @{
            FlowId = $flowB; RunId = 'b-failed'; CallingRecordId = $true; RecordSource = 'Dataverse'; IdOnly = $true
        }).Count 0
    }
    Invoke-Test 'Errors and CallingRecordId compose without downloading every action input' {
        Set-Scenario
        $item = @(Invoke-History @{
            FlowId = $flowB; RunId = 'b-failed'; CallingRecordId = $true; Errors = $true
        })[0]
        Assert-Equal $item.CallingRecord.RecordId '42'
        Assert-True ($item.Errors.Count -gt 0) 'Errors projection missing.'
        Assert-True (@(Get-Requests | Where-Object Path -match '/content/action-.+-input').Count -eq 0) 'Action inputs downloaded for Errors.'
    }
    Invoke-Test 'Secured, missing, expired, deleted, malformed, and oversized payloads remain explicit' {
        foreach ($scenarioName in @('secured', 'missing-payload', 'expired-payload', 'deleted-payload', 'invalid-payload', 'oversize-payload')) {
            Set-Scenario $scenarioName
            $item = @(Invoke-History @{
                FlowId = $flowA; RunId = 'run-failed'; CallingRecordId = $true; MaxPayloadMB = 1
            })[0]
            Assert-Equal $item.CallingRecord.RecordId $null
            Assert-True ($item.Issues.Count -gt 0 -and $item.DetailCoverage -eq 'Partial') "$scenarioName did not report incomplete data."
            if ($scenarioName -eq 'secured') {
                Assert-Equal @(Get-Requests | Where-Object Path -eq '/content/dv-output').Count 0
            }
        }
    }
    Invoke-Test 'Unsupported repetitions and action-list fallback never claim full capture' {
        foreach ($scenarioName in @('repetitions-unsupported', 'actions-unsupported', 'definition-denied')) {
            Set-Scenario $scenarioName
            $item = @(Invoke-History @{ FlowId = $flowA; RunId = 'run-failed'; All = $true })[0]
            Assert-Equal $item.DetailCoverage 'Partial'
            Assert-True ($item.Issues.Count -gt 0) 'Missing detail limitation.'
        }
        Invoke-Test 'Binary payloads preserve all bytes and empty text is not empty JSON' {
            Set-Scenario 'binary-payload'
            $item = @(Invoke-History @{ FlowId = $flowA; RunId = 'run-failed'; All = $true })[0]
            Assert-Equal $item.Trigger.Outputs.Content.'$content-type' 'application/octet-stream'
            Assert-Equal $item.Trigger.Outputs.Content.'$content' 'AP8BgA=='
            Set-Scenario 'empty-text'
            $item = @(Invoke-History @{ FlowId = $flowA; RunId = 'run-failed'; All = $true })[0]
            Assert-Equal $item.Trigger.Outputs.Availability 'Available'
            Assert-Equal $item.Trigger.Outputs.Content ''
            Set-Scenario 'empty-json'
            $item = @(Invoke-History @{ FlowId = $flowA; RunId = 'run-failed'; All = $true })[0]
            Assert-Equal $item.Trigger.Outputs.Availability 'Unreadable'
            Assert-Equal $item.DetailCoverage 'Partial'
        }
    }
    Invoke-Test 'A denied run detail after permitted admin history remains a partial result' {
        Set-Scenario 'detail-denied'
        $items = @(Invoke-History @{ FlowId = $flowA; AsAdmin = $true; Errors = $true; Status = 'Failed' })
        Assert-Equal $items.Count 3
        Assert-True (@($items | Where-Object DetailCoverage -ne 'Partial').Count -eq 0) 'Denied run detail looks complete.'
    }
    Invoke-Test 'Signed payload requests are anonymous; returned metadata/header strings are redacted' {
        Set-Scenario
        $item = @(Invoke-History @{ FlowId = $flowA; RunId = 'run-failed'; All = $true })[0]
        $contentRequests = @(Get-Requests | Where-Object Path -like '/content/*')
        Assert-True ($contentRequests.Count -gt 0) 'No content requests exercised.'
        Assert-True (@($contentRequests | Where-Object HasAuthorization).Count -eq 0) 'Bearer token leaked.'
        $json = $item | ConvertTo-Json -Depth 100
        Assert-True ($json -notmatch 'fixture-secret|fixture-sensitive-value|fixture-not-a-real-credential') 'Secret survived redaction.'
    }
    Invoke-Test 'Arbitrary payload hosts and content redirects are blocked without leaking signed links' {
        foreach ($scenarioName in @('blocked-host', 'redirect-payload')) {
            Set-Scenario $scenarioName
            $item = @(Invoke-History @{ FlowId = $flowA; RunId = 'run-failed'; CallingRecordId = $true })[0]
            Assert-Equal $item.DetailCoverage 'Partial'
            Assert-True (@(Get-Requests | Where-Object Path -eq '/leaked').Count -eq 0) 'Redirect was followed.'
            Assert-True (($item | ConvertTo-Json -Depth 100) -notmatch 'fixture-secret') 'Signed URL leaked in error output.'
        }
    }
    Invoke-Test 'Power Platform user-content validation is narrowly scoped to HTTPS automation storage' {
        $tokens = $null; $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
        $node = $ast.Find({
            param($candidate)
            $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and $candidate.Name -eq 'Assert-ContentUri'
        }, $true)
        $validator = $node.Body.GetScriptBlock()
        $TestApiBaseUri = $null
        $apiBase = [uri]'https://api.flow.microsoft.com'
        $hostName = 'aaaaaaaaaaaaaaaaaaaaaaaaaa.05.environment.api.powerplatformusercontent.com'
        & $validator ([uri]"https://$hostName/storage/powerautomate/automations/fixture/contents?sig=fixture-secret")
        foreach ($uri in @(
            "http://$hostName/storage/powerautomate/automations/fixture",
            "https://${hostName}:444/storage/powerautomate/automations/fixture",
            "https://$hostName.evil.invalid/storage/powerautomate/automations/fixture",
            'https://environment.api.powerplatformusercontent.com/storage/powerautomate/automations/fixture',
            "https://$hostName/elsewhere/fixture",
            "https://$hostName/storage/powerautomate/automations/../other/fixture",
            "https://user:password@$hostName/storage/powerautomate/automations/fixture"
        )) {
            Assert-Throws { & $validator ([uri]$uri) } 'Content link|content link|user-content'
        }
    }
    Invoke-Test 'Paging links cannot escape their origin/collection, and cycles stop immediately' {
        foreach ($scenarioName in @('evil-paging', 'cycle-paging')) {
            Set-Scenario $scenarioName
            Assert-Throws { Invoke-History @{ FlowId = $flowA } } 'paging link'
            Assert-Equal @(Get-Requests).Count 1
        }
        Set-Scenario 'relative-paging'
        Assert-Equal @(Invoke-History @{ FlowId = $flowA }).Count 5
    }
    Invoke-Test 'Service redirects, 401, and 403 are explicit non-retried failures' {
        foreach ($scenarioName in @('redirect-service', 'unauthorized', 'forbidden')) {
            Set-Scenario $scenarioName
            Assert-Throws { Invoke-History @{ FlowId = $flowA; MaxRetries = 3 } } 'HTTP (302|401|403)'
            Assert-Equal @(Get-Requests).Count 1
        }
    }
    Invoke-Test '429 / Retry-After seconds and dates / transient 503 recover within bounds' {
        foreach ($scenarioName in @('throttled', 'retry-date', 'server-error')) {
            Set-Scenario $scenarioName
            Assert-Equal @(Invoke-History @{ FlowId = $flowA; MaxRetries = 1 }).Count 5
            Assert-Equal @(Get-Requests).Count 4
        }
    }
    Invoke-Test 'Persistent throttling is bounded and Retry-After is not shortened to fit the budget' {
        Set-Scenario 'always-throttled'
        Assert-Throws { Invoke-History @{ FlowId = $flowA; MaxRetries = 2 } } 'HTTP 429'
        Assert-Equal @(Get-Requests).Count 3
        Set-Scenario 'retry-budget'
        Assert-Throws { Invoke-History @{ FlowId = $flowA; MaxRetries = 2; RetryBudgetSeconds = 1 } } 'Retry-After was not shortened'
        Assert-Equal @(Get-Requests).Count 1
    }
    Invoke-Test 'Invalid JSON/collection shape fails explicitly rather than returning an empty history' {
        foreach ($scenarioName in @('invalid-json', 'invalid-collection', 'invalid-value-shape')) {
            Set-Scenario $scenarioName
            Assert-Throws { Invoke-History @{ FlowId = $flowA } } 'invalid JSON|value array collection'
        }
    }
    Invoke-Test 'SecureString token and explicit alternate tenant work without any Az context' {
        Set-Scenario
        $secureToken = ConvertTo-SecureString (New-TestToken -Tenant $otherTenant) -AsPlainText -Force
        $items = @(Invoke-History @{ FlowId = $flowA; TenantId = $otherTenant; AccessToken = $secureToken })
        Assert-Equal $items.Count 5
        Assert-True (@(Get-Requests | Where-Object { -not $_.HasAuthorization }).Count -eq 0) 'Flow request was not authenticated.'
    }
    Invoke-Test 'TenantId remains explicit in every normal result projection without an extra tenant lookup' {
        foreach ($mode in @(@{}, @{ CallingRecordId = $true }, @{ Errors = $true }, @{ All = $true })) {
            Set-Scenario
            $options = @{
                FlowId = $flowA; RunId = 'run-failed'; TenantId = $otherTenant
                AccessToken = (New-TestToken -Tenant $otherTenant)
            }
            foreach ($key in $mode.Keys) { $options[$key] = $mode[$key] }
            $items = @(Invoke-History $options)
            Assert-Equal $items.Count 1
            Assert-Equal $items[0].TenantId $otherTenant
            if ($mode.Count -eq 0) { Assert-Equal @(Get-Requests).Count 1 }
        }
    }
    Invoke-Test 'Wrong tenant/audience, expired/not-yet-valid, app-only, and malformed tokens send no requests' {
        $tokens = @(
            (New-TestToken -Tenant $otherTenant),
            (New-TestToken -Audience 'https://graph.microsoft.com/'),
            (New-TestToken -Expiry 1),
            (New-TestToken -NotBefore ([DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds())),
            (New-TestToken -AppOnly), 'invalid'
        )
        foreach ($token in $tokens) {
            Set-Scenario
            Assert-Throws { Invoke-History @{ FlowId = $flowA; AccessToken = $token } } 'tenant|audience|expired|valid yet|delegated|JWT'
            Assert-Equal @(Get-Requests).Count 0
        }
    }
    Invoke-Test 'Dataverse token must match both tenant and explicit organization audience' {
        foreach ($token in @((New-TestToken), (New-TestToken -Tenant $otherTenant -Audience 'https://fixture.crm.dynamics.com/'))) {
            Set-Scenario
            Assert-Throws {
                Invoke-History @{
                    FlowId = $flowA; CallingRecordId = $true; DataverseUrl = 'https://fixture.crm.dynamics.com/'
                    DataverseAccessToken = $token
                }
            } 'tenant|audience'
            Assert-Equal @(Get-Requests).Count 0
        }
    }
    Invoke-Test 'Invalid switches, arrays, dates, and non-loopback test origins fail before network activity' {
        $cases = @(
            @{ FlowId = $flowA; AllFlows = $true },
            @{ FlowId = @() }, @{ RunId = @() }, @{ Status = @() }, @{ FlowId = 'invalid' }, @{ RunId = '../invalid' },
            @{ CallingRecordId = $true; RecordSource = @() },
            @{ IdOnly = $true }, @{ CallingRecordId = $true; IdOnly = $true; Errors = $true },
            @{ RecordSource = 'Dataverse' }, @{ LastDays = 7; From = '2026-11-01T00:00:00Z' },
            @{ From = '2026-11-01' }, @{ From = '2026-11-01T00:00:00' },
            @{ From = '' }, @{ To = '' },
            @{ From = '2026-11-10T00:00:00Z'; To = '2026-11-01T00:00:00Z' },
            @{ DataverseAccessToken = (New-TestToken) }, @{ DataverseUrl = 'http://example.invalid' },
            @{ TestApiBaseUri = 'http://example.invalid' }, @{ UseExistingContext = $true },
            @{ DataversePrimaryKey = @{ accounts = 'bad/name' } }
        )
        foreach ($case in $cases) {
            Set-Scenario
            Assert-Throws { Invoke-History $case } '.'
            Assert-Equal @(Get-Requests).Count 0
        }
    }
    Invoke-Test 'Export JSON preserves zero, one, and many structured results as arrays and retains pipeline objects' {
        foreach ($count in @(0, 1, 5)) {
            Set-Scenario
            $path = Get-TestExportPath 'json'
            $options = @{ FlowId = $flowA; JsonPath = $path }
            if ($count -eq 0) { $options.Status = 'Suspended' }
            if ($count -eq 1) { $options.RunId = 'run-failed' }
            $items = @(Invoke-History $options)
            Assert-Equal $items.Count $count
            $text = [IO.File]::ReadAllText($path).Trim()
            Assert-True ($text.StartsWith('[') -and $text.EndsWith(']')) 'JSON export is not an array.'
            if ($count -eq 0) { Assert-Equal $text '[]' }
            else {
                $decoded = $text | ConvertFrom-Json
                $decoded = @($decoded)
                Assert-Equal $decoded.Count $count
                Assert-Equal $decoded[0].RunId $items[0].RunId
                Assert-Equal $decoded[0].TenantId $tenant
                Assert-Equal $items[0].TenantId $tenant
                Assert-Equal $items[0].FlowDisplayName "Fixture flow $flowA"
            }
            Assert-NoStagingFiles
        }
    }
    Invoke-Test 'Export CSV uses stable headers with no matches and summary rows without extra payload requests' {
        Set-Scenario
        $emptyCsv = Get-TestExportPath 'csv'
        $emptyJson = Get-TestExportPath 'json'
        $none = @(Invoke-History @{ FlowId = $flowA; Status = 'Suspended'; CsvPath = $emptyCsv; JsonPath = $emptyJson })
        Assert-Equal $none.Count 0
        Assert-Equal @(Import-Csv -LiteralPath $emptyCsv -Encoding UTF8).Count 0
        $header = [IO.File]::ReadAllText($emptyCsv).Trim()
        Assert-True ($header.StartsWith('"RowType","TenantId","EnvironmentName","FlowId","FlowDisplayName","RunId"')) 'Stable header missing.'
        Assert-True ($header -match '"MetadataJson"') 'Lossless metadata column missing.'
        Assert-Equal ([IO.File]::ReadAllText($emptyJson).Trim()) '[]'
        $csv = Get-TestExportPath 'csv'
        $items = @(Invoke-History @{ FlowId = $flowA; CsvPath = $csv })
        $rows = @(Import-Csv -LiteralPath $csv -Encoding UTF8)
        Assert-Equal $rows.Count 5
        Assert-True (@($rows | Where-Object RowType -ne 'Run').Count -eq 0) 'Summary export changed output mode.'
        Assert-Equal $rows[0].FlowDisplayName "Fixture flow $flowA"
        Assert-Equal $items[0].RunId $rows[0].RunId
        Assert-True (@(Get-Requests | Where-Object Path -match '/actions|/content').Count -eq 0) 'Summary exports downloaded payloads.'
        Assert-Equal @(Get-Requests | Where-Object Path -match "/flows/$flowA$").Count 1
        Assert-NoStagingFiles
    }
    Invoke-Test 'Export All CSV has run, trigger, action and repetition rows with correlations, durations and nested JSON' {
        Set-Scenario
        $csv = Get-TestExportPath 'csv'
        $json = Get-TestExportPath 'json'
        $items = @(Invoke-History @{
            FlowId = $flowA; RunId = 'run-failed'; All = $true; CallingRecordId = $true
            DataversePrimaryKey = @{ accounts = 'accountid' }; CsvPath = $csv; JsonPath = $json
        })
        Assert-Equal $items.Count 1
        $rows = @(Import-Csv -LiteralPath $csv -Encoding UTF8)
        Assert-Equal $rows.Count 10
        foreach ($type in @('Run', 'Trigger', 'Action', 'ActionRepetition', 'ScopeRepetition')) {
            Assert-True ($type -in $rows.RowType) "$type rows are missing."
        }
        Assert-True (@($rows | Where-Object RecordId -ne $rowId).Count -eq 0) 'Record context was lost on operation rows.'
        Assert-True (@($rows | Where-Object TenantId -ne $tenant).Count -eq 0) 'Tenant context was lost on operation rows.'
        $inner = @($rows | Where-Object { $_.RowType -eq 'Action' -and $_.OperationName -eq 'Inner' })[0]
        Assert-Equal $inner.ClientTrackingId 'action-client-track'
        Assert-Equal $inner.ActionTrackingId 'action-track-Inner'
        Assert-Equal $inner.TrackingId 'operation-track-Inner'
        Assert-Equal $inner.ClientRequestId 'request-Inner'
        Assert-Equal $inner.ServiceRequestId 'service-Inner'
        Assert-Equal $inner.DefinitionPath 'Scope/Inner'
        Assert-Equal $inner.DurationSeconds '1.25'
        Assert-Equal $inner.ErrorMessage 'Detailed action output: Inner'
        Assert-Equal $inner.InputsAvailability 'Available'
        Assert-Equal (($inner.OutputsJson | ConvertFrom-Json).body.error.message) 'Detailed action output: Inner'
        Assert-Equal (($inner.MetadataJson | ConvertFrom-Json).properties.status) 'Failed'
        $iteration = @($rows | Where-Object { $_.RowType -eq 'ActionRepetition' -and $_.RepetitionName -eq '000001' })[0]
        $indexes = $iteration.RepetitionIndexesJson | ConvertFrom-Json
        Assert-Equal @($indexes).Count 2
        Assert-Equal $iteration.Status 'Failed'
        Assert-Equal $iteration.DurationSeconds '0.25'
        Assert-Equal $iteration.OperationName 'Write_Record'
        Assert-True ([IO.File]::ReadAllText($json).Contains((ConvertTo-Json -InputObject $items[0] -Depth 100 -Compress))) 'JSON is not the full pipeline structure.'
        Assert-NoStagingFiles
    }
    Invoke-Test 'Export Errors CSV retains operation details without changing pipeline projection or downloading inputs' {
        Set-Scenario
        $csv = Get-TestExportPath 'csv'
        $items = @(Invoke-History @{ FlowId = $flowA; RunId = 'run-failed'; Errors = $true; CsvPath = $csv })
        Assert-True ('Actions' -notin $items[0].PSObject.Properties.Name) 'CSV export expanded the pipeline projection.'
        $rows = @(Import-Csv -LiteralPath $csv -Encoding UTF8)
        Assert-Equal $rows.Count 10
        $inner = @($rows | Where-Object { $_.RowType -eq 'Action' -and $_.OperationName -eq 'Inner' })[0]
        Assert-Equal $inner.ErrorMessage 'Detailed action output: Inner'
        Assert-Equal $inner.InputsAvailability 'NotRequested'
        Assert-Equal $inner.OutputsAvailability 'Available'
        Assert-True (@(Get-Requests | Where-Object Path -match '-input$').Count -eq 0) 'Export changed requested payload mode.'
    }
    Invoke-Test 'Export CSV quote/newline/Unicode cells and embedded JSON round-trip without culture loss' {
        Set-Scenario 'export-text'
        $csv = Get-TestExportPath 'csv'
        $json = Get-TestExportPath 'json'
        $culture = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('de-DE')
            $items = @(Invoke-History @{ FlowId = $flowA; RunId = 'run-failed'; All = $true; CsvPath = $csv; JsonPath = $json })
        }
        finally { [Threading.Thread]::CurrentThread.CurrentCulture = $culture }
        $rows = @(Import-Csv -LiteralPath $csv -Encoding UTF8)
        $run = @($rows | Where-Object RowType -eq 'Run')[0]
        Assert-Equal $run.ErrorMessage $exportText
        Assert-Equal $run.FlowDisplayName $exportText
        Assert-Equal $run.RunDurationSeconds '1.25'
        Assert-Equal (($run.MetadataJson | ConvertFrom-Json).properties.error.message) $exportText
        Assert-Equal $items[0].FlowDisplayName $exportText
        $decoded = @([IO.File]::ReadAllText($json) | ConvertFrom-Json)
        Assert-Equal $decoded[0].FlowDisplayName $exportText
        Assert-Equal ([IO.File]::ReadAllBytes($csv)[0..2] -join ',') '239,187,191' 'CSV must have a consistent UTF-8 BOM.'
        Assert-NoStagingFiles
    }
    Invoke-Test 'Export IdOnly CSV is genuinely one column and JSON is an array of ID strings, including no matches' {
        foreach ($excluded in @($false, $true)) {
            Set-Scenario
            $csv = Get-TestExportPath 'csv'
            $json = Get-TestExportPath 'json'
            $options = @{
                FlowId = $flowB; RunId = 'b-failed'; CallingRecordId = $true; IdOnly = $true
                CsvPath = $csv; JsonPath = $json
            }
            if ($excluded) { $options.RecordSource = 'Dataverse' }
            $items = @(Invoke-History $options)
            $text = [IO.File]::ReadAllText($csv)
            Assert-Equal ($text -split '\r?\n')[0] '"RecordId"'
            $rows = @(Import-Csv -LiteralPath $csv -Encoding UTF8)
            if ($excluded) {
                Assert-Equal $rows.Count 0
                Assert-Equal ([IO.File]::ReadAllText($json).Trim()) '[]'
            }
            else {
                Assert-Equal $items[0] '42'
                Assert-Equal $rows.Count 1
                Assert-Equal $rows[0].RecordId '42'
                Assert-Equal @($rows[0].PSObject.Properties.Name).Count 1
                Assert-Equal (@([IO.File]::ReadAllText($json) | ConvertFrom-Json)[0]) '42'
                Assert-True ([IO.File]::ReadAllText($json) -notmatch 'TenantId') 'IdOnly JSON was expanded with tenant context.'
            }
            Assert-NoStagingFiles
        }
    }
    Invoke-Test 'Export CallingRecordId projection keeps identity/context without persisting trigger payloads' {
        Set-Scenario
        $csv = Get-TestExportPath 'csv'
        $json = Get-TestExportPath 'json'
        $items = @(Invoke-History @{
            FlowId = $flowB; RunId = 'b-failed'; CallingRecordId = $true; CsvPath = $csv; JsonPath = $json
        })
        $rows = @(Import-Csv -LiteralPath $csv -Encoding UTF8)
        Assert-Equal $rows.Count 1
        Assert-Equal $rows[0].RecordId '42'
        Assert-Equal $rows[0].TenantId $tenant
        Assert-Equal $rows[0].SiteUrl 'https://contoso.sharepoint.com/sites/fixture'
        Assert-Equal $rows[0].FlowDisplayName "Fixture flow $flowB"
        Assert-Equal $rows[0].InputsJson ''
        Assert-Equal $rows[0].OutputsJson ''
        Assert-Equal $rows[0].MetadataJson ''
        Assert-True ([IO.File]::ReadAllText($json) -notmatch 'fixture payload|folder/file.txt') 'Record-only JSON retained trigger business data.'
        Assert-Equal $items[0].CallingRecord.RecordId '42'
    }
    Invoke-Test 'Export files preserve explicit partial coverage and redact signed links and bearer values' {
        foreach ($scenarioName in @('normal', 'secured', 'repetitions-unsupported')) {
            Set-Scenario $scenarioName
            $csv = Get-TestExportPath 'csv'
            $json = Get-TestExportPath 'json'
            $null = Invoke-History @{ FlowId = $flowA; RunId = 'run-failed'; All = $true; CsvPath = $csv; JsonPath = $json }
            $rows = @(Import-Csv -LiteralPath $csv -Encoding UTF8)
            if ($scenarioName -ne 'normal') {
                Assert-True (@($rows | Where-Object DetailCoverage -ne 'Partial').Count -eq 0) 'Partial data looked complete in CSV.'
                Assert-True (($rows[0].IssuesJson | ConvertFrom-Json).Count -gt 0) 'CSV issues were omitted.'
            }
            foreach ($path in @($csv, $json)) {
                Assert-True ([IO.File]::ReadAllText($path) -notmatch 'fixture-secret|fixture-sensitive-value|fixture-not-a-real-credential') 'An export leaked a bearer secret.'
            }
            Assert-NoStagingFiles
        }
    }
    Invoke-Test 'Export late auth/paging failures and missing selected runs publish no final files or staging debris' {
        foreach ($scenarioName in @('late-auth', 'late-paging', 'missing-run')) {
            Set-Scenario $scenarioName
            $csv = Get-TestExportPath 'csv'
            $json = Get-TestExportPath 'json'
            $options = @{ FlowId = @($flowA, $flowB); CsvPath = $csv; JsonPath = $json }
            if ($scenarioName -eq 'missing-run') { $options.RunId = @('run-failed', 'not-retained') }
            Assert-Throws { Invoke-History $options } 'HTTP 401|paging link|not found'
            Assert-True (-not [IO.File]::Exists($csv) -and -not [IO.File]::Exists($json)) 'An incomplete traversal published apparently complete exports.'
            Assert-NoStagingFiles
        }
    }
    Invoke-Test 'Export existing/invalid/identical destinations are rejected before HTTP without overwriting anything' {
        Set-Scenario
        $existing = Get-TestExportPath 'json'
        [IO.File]::WriteAllText($existing, 'keep this existing content')
        $newCsv = Get-TestExportPath 'csv'
        Assert-Throws { Invoke-History @{ FlowId = $flowA; CsvPath = $newCsv; JsonPath = $existing } } 'already exists'
        Assert-Equal ([IO.File]::ReadAllText($existing)) 'keep this existing content'
        Assert-True (-not [IO.File]::Exists($newCsv)) 'Another export was published despite failed preflight.'
        $same = Get-TestExportPath 'json'
        Assert-Throws { Invoke-History @{ FlowId = $flowA; CsvPath = $same; JsonPath = $same } } 'different files'
        $missingParent = Join-Path (Join-Path $exportRoot 'does-not-exist') 'file.csv'
        foreach ($options in @(@{ CsvPath = '' }, @{ JsonPath = '' }, @{ CsvPath = $missingParent }, @{ JsonPath = $exportRoot })) {
            Assert-Throws { Invoke-History $options } 'empty|already exist|must already exist'
        }
        Assert-Equal @(Get-Requests).Count 0
        Assert-NoStagingFiles
    }
    Invoke-Test 'Export destinations created concurrently are preserved and both staged outputs are discarded' {
        Set-Scenario
        $csv = Get-TestExportPath 'csv'
        $json = Get-TestExportPath 'json'
        $arguments = @{} + $defaults + @{ FlowId = $flowA; CsvPath = $csv; JsonPath = $json }
        Assert-Throws {
            & $scriptPath @arguments | ForEach-Object {
                if (-not [IO.File]::Exists($json)) { [IO.File]::WriteAllText($json, 'concurrent writer content') }
            }
        } 'destination appeared'
        Assert-Equal ([IO.File]::ReadAllText($json)) 'concurrent writer content'
        Assert-True (-not [IO.File]::Exists($csv)) 'A sibling export published after the destination race was detected.'
        Assert-NoStagingFiles
    }
    Invoke-Test 'Export interrupted by a downstream pipeline consumer is not published' {
        Set-Scenario
        $csv = Get-TestExportPath 'csv'
        $json = Get-TestExportPath 'json'
        $arguments = @{} + $defaults + @{ FlowId = $flowA; CsvPath = $csv; JsonPath = $json }
        $null = & $scriptPath @arguments | Select-Object -First 1
        Assert-True (-not [IO.File]::Exists($csv) -and -not [IO.File]::Exists($json)) 'A stopped pipeline published incomplete exports.'
        Assert-NoStagingFiles
    }
    $env:PSModulePath = (Join-Path $PSScriptRoot 'fixtures') + [IO.Path]::PathSeparator + $originalModulePath
    Invoke-Test 'Interactive Az sign-in explicitly selects target tenant and commercial cloud' {
        Set-Scenario
        $global:FlowHistoryAuthFixture = New-AuthFixture
        $items = @(Invoke-History @{ FlowId = $flowA } -WithoutToken)
        Assert-Equal $items.Count 5
        $connect = @($global:FlowHistoryAuthFixture.Calls | Where-Object Command -eq 'Connect')
        Assert-Equal $connect.Count 1
        Assert-Equal $connect[0].Tenant $tenant
        Assert-Equal $connect[0].Environment 'AzureCloud'
        Assert-Equal $connect[0].Scope 'Process'
        $tokens = @($global:FlowHistoryAuthFixture.Calls | Where-Object Command -eq 'Token')
        Assert-True (@($tokens | Where-Object TenantId -ne $tenant).Count -eq 0) 'Token acquisition did not specify the target tenant.'
        Assert-True (@($tokens | Where-Object ResourceUrl -ne 'https://service.flow.microsoft.com/').Count -eq 0) 'Incorrect resource passed to Az.'
    }
    Invoke-Test 'Existing Az context must match target tenant, user type, and cloud without switching it' {
        foreach ($fixture in @(
            (New-AuthFixture -ContextTenant $otherTenant),
            (New-AuthFixture -AccountType 'ServicePrincipal'),
            (New-AuthFixture -Cloud 'AzureUSGovernment')
        )) {
            Set-Scenario
            $global:FlowHistoryAuthFixture = $fixture
            Assert-Throws { Invoke-History @{ FlowId = $flowA; UseExistingContext = $true } -WithoutToken } 'Az context'
            Assert-Equal @(Get-Requests).Count 0
            Assert-Equal @($fixture.Calls | Where-Object Command -eq 'Connect').Count 0
        }
        Set-Scenario
        $global:FlowHistoryAuthFixture = New-AuthFixture
        Assert-Equal @(Invoke-History @{ FlowId = $flowA; UseExistingContext = $true } -WithoutToken).Count 5
        Assert-Equal @($global:FlowHistoryAuthFixture.Calls | Where-Object Command -eq 'Connect').Count 0
    }
    Invoke-Test 'Every feature request is read-only GET' {
        Set-Scenario
        $null = Invoke-History @{
            FlowId = $flowA; RunId = 'run-failed'; All = $true; Errors = $true; CallingRecordId = $true
            DataversePrimaryKey = @{ accounts = 'accountid' }
        }
        Assert-True (@(Get-Requests | Where-Object Method -ne 'GET').Count -eq 0) 'Script mutated a service resource.'
    }
}
finally {
    $env:PSModulePath = $originalModulePath
    Remove-Module Az.Accounts -ErrorAction SilentlyContinue
    Remove-Variable -Name FlowHistoryAuthFixture -Scope Global -ErrorAction SilentlyContinue
    if ($null -ne $job) {
        if ($job.State -eq 'Running') {
            try {
                $null = Invoke-RestMethod -Uri "$base/_stop" -TimeoutSec 2
                $null = Wait-Job $job -Timeout 10
            }
            catch { Write-Warning 'Mock server did not stop gracefully; stopping its owned job.' }
        }
        if ($job.State -eq 'Running') { Stop-Job $job }
        Remove-Job $job -Force
    }
    [IO.Directory]::Delete($exportRoot, $true)
}

$failed = @($results | Where-Object { -not $_.Passed })
if ($results.Count -eq 0) { throw 'No tests matched TestName.' }
$report = [pscustomobject]@{
    PSVersion = $PSVersionTable.PSVersion.ToString(); PSEdition = $PSVersionTable.PSEdition
    Passed = $results.Count - $failed.Count; Failed = $failed.Count
    Seconds = [Math]::Round($timer.Elapsed.TotalSeconds, 2); Tests = $results.ToArray()
    Scope = 'Offline mock-HTTP tests; not live service or cross-tenant verification.'
}
if ($ResultsPath) {
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ResultsPath -Encoding UTF8
}
Write-Host "PowerShell $($report.PSVersion) ($($report.PSEdition)): $($report.Passed) passed, $($report.Failed) failed in $($report.Seconds)s."
if ($failed.Count -gt 0) { exit 1 }

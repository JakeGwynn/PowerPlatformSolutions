#Requires -Version 7.4
[CmdletBinding()]
param(
    [switch]$SkipScale,
    [ValidateRange(100000, 1000000)][int]$ScaleApps = 100000,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\.test-output'),
    [switch]$KeepOutput,
    [ValidateSet('', 'Create', 'Resume')][string]$ProcessProbe = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\Inventory.psm1') -Force
$module = Get-Module Inventory
$testRoot = Join-Path ([System.IO.Path]::GetFullPath($OutputDirectory)) ([guid]::NewGuid().ToString())
[System.IO.Directory]::CreateDirectory($testRoot) | Out-Null
$results = [System.Collections.Generic.List[object]]::new()
$tenant = '11111111-1111-4111-8111-111111111111'
$timer = [System.Diagnostics.Stopwatch]::StartNew()

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) { throw "$Message (expected '$Expected', got '$Actual')" }
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
            throw "Unexpected exception: $($_.Exception.Message); expected /$Pattern/"
        }
    }
    if (-not $caught) { throw "Expected an exception matching /$Pattern/" }
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Action)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $Action
        $results.Add(@{ Name = $Name; Passed = $true; Seconds = $watch.Elapsed.TotalSeconds })
        Write-Host "PASS $Name"
    }
    catch {
        $results.Add(@{
            Name = $Name; Passed = $false; Seconds = $watch.Elapsed.TotalSeconds
            Error = $_.Exception.Message; Location = $_.ScriptStackTrace
        })
        Write-Host "FAIL $Name : $($_.Exception.Message)"
        Write-Host $_.ScriptStackTrace
    }
}

function Get-TestEnvironmentId {
    param([int]$Number)
    return '00000000-0000-4000-8000-{0:D12}' -f $Number
}

function Get-TestAppId {
    param([int]$Number)
    return '{0:x8}-0000-4000-8000-000000000001' -f $Number
}

function Get-TestEnvironment {
    param($Fixture, [int]$Number)
    $managed = $false
    $type = 'Developer'
    if ($Number % 10 -eq 9) { $managed = $true }
    if ($Number % 10 -eq 0) { $type = 'Production' }
    if ($Number -eq $Fixture.UnknownEnvironment) { $managed = $null }
    return @{
        id = '/environments/' + (Get-TestEnvironmentId $Number)
        name = Get-TestEnvironmentId $Number; tenantId = $Fixture.Tenant
        type = 'microsoft.powerplatform/environments'; location = 'unitedstates'
        properties = @{ displayName = "Environment $Number"; environmentType = $type; isManaged = $managed }
    }
}

function Get-TestApp {
    param($Fixture, [int]$Number, [string]$Source)
    $environmentNumber = ($Number - 1) % $Fixture.EnvironmentCount + 1
    $environment = Get-TestEnvironment $Fixture $environmentNumber
    $category = [int][Math]::Floor(($Number - 1) / $Fixture.EnvironmentCount) % 10
    $appId = Get-TestAppId $Number
    if ($Source -eq 'AdminApps') {
        $reference = @{ id = '/providers/Microsoft.PowerApps/apis/shared_test'; apiTier = 'Standard' }
        if ($category -in @(0, 3)) { $reference.apiTier = 'Premium' }
        if ($category -in @(1, 4)) { $reference.isCustomApiConnection = $true }
        if ($category -eq 5) { $reference.isOnPremiseConnection = $true }
        return @{
            id = "/providers/Microsoft.PowerApps/apps/$appId"; name = $appId
            properties = @{
                displayName = "App $Number"; environment = @{ name = $environment.name }
                owner = @{
                    id = '22222222-2222-4222-8222-222222222222'
                    displayName = 'Synthetic Owner'; email = 'owner@example.invalid'
                }
                connectionReferences = @($reference)
                createdTime = '2026-01-01T00:00:00Z'; lastModifiedTime = '2026-02-01T00:00:00Z'
            }
        }
    }
    if ($Source -like 'Dataverse*') {
        return @{
            appmoduleid = $appId; name = "App $Number"; uniquename = "test_$Number"
            createdon = '2026-01-01T00:00:00Z'; modifiedon = '2026-02-01T00:00:00Z'
            componentstate = $(if ($Source -eq 'DataverseUnpublished') { 1 } else { 0 })
        }
    }
    $type = 'microsoft.powerapps/canvasapps'
    $subtype = ''
    if ($category -in @(6, 7)) { $type = 'microsoft.powerapps/modeldrivenapps' }
    if ($category -eq 8) { $type = 'microsoft.powerapps/codeapps'; $subtype = 'byocApp' }
    if ($category -eq 9) {
        if ($environmentNumber % 3 -eq 0) { $type = 'microsoft.powerapps/codeapps'; $subtype = 'vibeApp' }
        else {
            $type = 'microsoft.powerapps/apps'
            $subtype = if ($environmentNumber % 3 -eq 1) { 'microsoftApp' } else { 'appBuilderApp' }
        }
    }
    return @{
        id = "/apps/$appId"; name = $appId; tenantId = $Fixture.Tenant; type = $type
        location = 'unitedstates'; environmentName = $environment.properties.displayName
        environmentType = $environment.properties.environmentType
        isManagedEnvironment = $environment.properties.isManaged
        properties = @{
            environmentId = $environment.name; displayName = "App $Number"; subType = $subtype
            appModuleId = $(if ($category -eq 6) { $appId } else { '' })
            ownerId = '22222222-2222-4222-8222-222222222222'
            createdBy = '33333333-3333-4333-8333-333333333333'
            createdAt = '2026-01-01T00:00:00Z'; lastModifiedAt = '2026-02-01T00:00:00Z'
        }
    }
}

function New-TestToken {
    param($Fixture, [string]$Audience)
    $claims = @{
        tid = $Fixture.TokenTenant; oid = '44444444-4444-4444-8444-444444444444'
        aud = $Audience; exp = $Fixture.Now.AddHours(1).ToUnixTimeSeconds()
        scp = 'ResourceQuery.Resources.Read PowerApps.Apps.Read EnvironmentManagement.Environments.Read user_impersonation'
        wids = @($Fixture.Role); idtyp = 'user'
    }
    if ($Fixture.AppOnly) { $claims.Remove('scp'); $claims.idtyp = 'app' }
    $json = ConvertTo-Json -InputObject $claims -Compress
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    return "e30.$payload.synthetic-not-a-credential"
}

function New-Fixture {
    param([int]$Apps = 40, [int]$Environments = 4, [int]$PageSize = 7)
    if ($Apps -gt 0 -and $Apps % ($Environments * 10) -ne 0) {
        throw 'Synthetic app count must be divisible by 10 * environment count.'
    }
    $fixture = @{
        Tenant = $tenant; TokenTenant = $tenant; Role = '11648597-926c-4cf3-9c36-bcebb0ba8dcc'
        AppOnly = $false; Now = [DateTimeOffset]::Parse('2026-11-03T15:00:00Z')
        Apps = $Apps; EnvironmentCount = $Environments; PageSize = $PageSize
        Rounds = $(if ($Apps -gt 0) { [int]($Apps / ($Environments * 10)) } else { 0 })
        Output = Join-Path $testRoot ([guid]::NewGuid().ToString())
        UnknownEnvironment = -1; MissingUrlEnvironment = -1
        Calls = @{}; TokenCalls = @{}; Sleeps = [System.Collections.Generic.List[double]]::new()
        Actions = [System.Collections.Generic.Queue[object]]::new(); Transform = $null
        MaxRetries = 5; Budget = 900; Interval = 0; FaultHook = $null
    }
    $fixture.Clock = { return $fixture.Now }.GetNewClosure()
    $fixture.Sleep = {
        param($Milliseconds)
        $fixture.Sleeps.Add([double]$Milliseconds)
        $fixture.Now = $fixture.Now.AddMilliseconds($Milliseconds)
    }.GetNewClosure()
    $fixture.Provider = {
        param($Audience)
        if (-not $fixture.TokenCalls.ContainsKey($Audience)) { $fixture.TokenCalls[$Audience] = 0 }
        $fixture.TokenCalls[$Audience]++
        return New-TestToken $fixture $Audience
    }.GetNewClosure()
    $fixture.Transport = {
        param($Request)
        $uri = [Uri]$Request.Uri
        $environmentNumber = 0
        $offset = 0
        $inventory = $Request.Method -eq 'POST'
        if ($inventory) {
            Assert-Equal $Request.Body.TableName 'PowerPlatformResources' 'Wrong inventory table'
            Assert-Equal $Request.Body.Clauses[0].Values[0] "'$($fixture.Tenant)'" 'Tenant KQL literal must be quoted'
            Assert-True ($Request.Body.Options.Top -le 1000) 'Page size is not bounded'
            Assert-True (-not ($Request.Body.Options.ContainsKey('SkipToken') -and $Request.Body.Options.ContainsKey('Skip'))) 'Skip and SkipToken must not be combined'
            $kind = if ($Request.Body.Clauses[1].Operator -eq '==') { 'InventoryEnvironments' } else { 'InventoryApps' }
            if ($Request.Body.Options.ContainsKey('SkipToken')) {
                $offset = [int]($Request.Body.Options.SkipToken.Split('|')[-1])
            }
        }
        else {
            if ($uri.Host -match '^env-(\d+)\.crm\.dynamics\.com$') {
                $environmentNumber = [int]$Matches[1]
                $kind = if ($uri.AbsolutePath -like '*RetrieveUnpublishedMultiple*') { 'DataverseUnpublished' } else { 'DataversePublished' }
            }
            elseif ($uri.AbsolutePath -match '/environments/([^/]+)/apps$') {
                $environmentNumber = [int]($Matches[1].Split('-')[-1])
                $kind = 'AdminApps'
            }
            elseif ($uri.AbsolutePath -match '/environmentmanagement/environments/([^/]+)$') {
                $environmentNumber = [int]($Matches[1].Split('-')[-1])
                $kind = 'EnvironmentDetail'
            }
            else { throw "Unexpected test request endpoint: $($uri.AbsolutePath)" }
            if ([Net.WebUtility]::UrlDecode($uri.Query) -match '\$skiptoken=page/(\d+)') { $offset = [int]$Matches[1] }
        }
        if (-not $fixture.Calls.ContainsKey($kind)) { $fixture.Calls[$kind] = 0 }
        $fixture.Calls[$kind]++
        if ($fixture.Actions.Count -gt 0 -and $fixture.Actions.Peek().Kind -eq $kind) {
            $action = $fixture.Actions.Dequeue()
            if ($action.ContainsKey('Throw')) { throw $action.Throw }
            return @{ StatusCode = $action.Status; Headers = $action.Headers; Body = '{"error":"synthetic-private-response-body"}' }
        }
        if ($kind -eq 'EnvironmentDetail') {
            $body = @{
                id = Get-TestEnvironmentId $environmentNumber; tenantId = $fixture.Tenant
                url = "https://env-$environmentNumber.crm.dynamics.com"
            }
            if ($environmentNumber -eq $fixture.MissingUrlEnvironment) { $body.Remove('url') }
        }
        else {
            $total = switch ($kind) {
                'InventoryEnvironments' { $fixture.EnvironmentCount }
                'InventoryApps' { [int]($fixture.Apps * 9 / 10) }
                'AdminApps' { $fixture.Rounds * 6 }
                default { $fixture.Rounds }
            }
            $records = [System.Collections.Generic.List[object]]::new()
            $end = [Math]::Min($offset + $fixture.PageSize, $total)
            for ($ordinal = $offset; $ordinal -lt $end; $ordinal++) {
                if ($kind -eq 'InventoryEnvironments') {
                    $records.Add((Get-TestEnvironment $fixture ($ordinal + 1)))
                }
                else {
                    if ($kind -eq 'InventoryApps') {
                        $block = [int][Math]::Floor($ordinal / $fixture.EnvironmentCount)
                        $category = $block % 9
                        if ($category -ge 7) { $category++ }
                        $number = [int][Math]::Floor($block / 9) * $fixture.EnvironmentCount * 10 +
                            $category * $fixture.EnvironmentCount + $ordinal % $fixture.EnvironmentCount + 1
                    }
                    elseif ($kind -eq 'AdminApps') {
                        $number = [int][Math]::Floor($ordinal / 6) * $fixture.EnvironmentCount * 10 +
                            ($ordinal % 6) * $fixture.EnvironmentCount + $environmentNumber
                    }
                    else {
                        $category = if ($kind -eq 'DataverseUnpublished') { 7 } else { 6 }
                        $number = $ordinal * $fixture.EnvironmentCount * 10 +
                            $category * $fixture.EnvironmentCount + $environmentNumber
                    }
                    $records.Add((Get-TestApp $fixture $number $kind))
                }
            }
            $next = ''
            if ($end -lt $total) {
                if ($inventory) { $next = "opaque|$kind|$end" }
                else {
                    $initial = $Request.Uri -replace '&\$skiptoken=.*$', ''
                    $next = $initial + '&$skiptoken=page%2F' + $end
                }
            }
            if ($inventory) {
                $body = @{
                    count = $records.Count; totalRecords = $total; data = $records.ToArray()
                    resultTruncated = $(if ($next) { 0 } else { 1 }); skipToken = $next
                }
            }
            else {
                $body = @{ value = $records.ToArray() }
                if ($next) {
                    if ($kind -eq 'AdminApps') { $body.nextLink = $next }
                    else { $body.'@odata.nextLink' = $next }
                }
            }
        }
        if ($null -ne $fixture.Transform) { & $fixture.Transform $kind $Request $body $fixture }
        return @{
            StatusCode = 200; Headers = @{}
            Body = ConvertTo-Json -InputObject $body -Depth 30 -Compress
        }
    }.GetNewClosure()
    return $fixture
}

function Invoke-Fixture {
    param($Fixture, [switch]$Resume)
    $arguments = @{
        TenantId = $Fixture.Tenant; OutputDirectory = $Fixture.Output; PageSize = $Fixture.PageSize
        RequestIntervalMilliseconds = $Fixture.Interval; MaxRetries = $Fixture.MaxRetries
        RetryBudgetSeconds = $Fixture.Budget; TokenProvider = $Fixture.Provider
        Transport = $Fixture.Transport; Sleep = $Fixture.Sleep; Clock = $Fixture.Clock
        FaultHook = $Fixture.FaultHook; Resume = $Resume; WarningAction = 'SilentlyContinue'
    }
    return Invoke-DeveloperPremiumInventory @arguments
}

function Assert-ReportIds {
    param($Fixture)
    $ids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    Import-Csv (Join-Path $Fixture.Output 'AllApps.csv') | ForEach-Object {
        Assert-True ($ids.Add($_.AppId)) "Duplicate app ID: $($_.AppId)"
        Assert-Equal $_.TenantId $Fixture.Tenant 'Cross-tenant report row'
        Assert-Equal $_.EnvironmentType 'Developer' 'An excluded environment leaked into the target report'
        Assert-Equal $_.ManagedState 'Unmanaged' 'A managed environment leaked into the target report'
    }
    $expected = 0L
    for ($number = 1; $number -le $Fixture.Apps; $number++) {
        $environmentNumber = ($number - 1) % $Fixture.EnvironmentCount + 1
        if ($environmentNumber % 10 -notin @(9, 0)) {
            $expected++
            Assert-True ($ids.Contains((Get-TestAppId $number))) "Missing app ID: $number"
        }
    }
    Assert-Equal $ids.Count $expected 'Unexpected report ID count'
}

if ($ProcessProbe) {
    $f = New-Fixture -Apps 100 -Environments 10 -PageSize 3
    $f.Output = Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) 'inventory'
    if ($ProcessProbe -eq 'Create') {
        $f.FaultHook = {
            param($Event, $Spec, $Page)
            if ($Event -eq 'BeforeCheckpoint' -and $Spec.Kind -eq 'InventoryApps' -and $Page -eq 3) {
                throw [OperationCanceledException]::new('cross-process interruption')
            }
        }
        Assert-Throws { Invoke-Fixture $f } 'cross-process interruption'
    }
    else {
        $summary = Invoke-Fixture $f -Resume
        Assert-Equal $summary.ReportedApps 80 'Cross-process resume count'
        Assert-ReportIds $f
    }
    exit 0
}

Invoke-Test 'Public command exposes its synopsis, parameters, and runnable help examples' {
    $scriptPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Get-UnmanagedDeveloperPremiumApps.ps1'))
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
    $help = $ast.GetHelpContent()
    Assert-True ($null -ne $help) 'PowerShell did not recognize the comment-based help'
    Assert-True ($help.Synopsis -match 'unmanaged Developer') 'Missing public synopsis'
    Assert-Equal @($help.Examples).Count 2 'Missing runnable invocation/resume examples'
}

Invoke-Test 'Actual HTTP transport reads content and enforces a response-body timeout' {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public sealed class InventoryTestHandler : HttpMessageHandler
{
    public bool Slow;
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
    {
        Stream stream = Slow ? (Stream)new InventorySlowStream() :
            new MemoryStream(Encoding.UTF8.GetBytes("{\"value\":[]}"));
        return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(stream) });
    }
}

public sealed class InventorySlowStream : Stream
{
    public override bool CanRead => true;
    public override bool CanSeek => false;
    public override bool CanWrite => false;
    public override long Length => 0;
    public override long Position { get => 0; set => throw new NotSupportedException(); }
    public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    public override async Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken token)
    {
        await Task.Delay(5000, token);
        return 0;
    }
    public override void Flush() { }
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
}
'@
    $handler = [InventoryTestHandler]::new()
    $client = [Net.Http.HttpClient]::new($handler)
    try {
        $response = & $module {
            param($Client)
            Invoke-HttpTransport @{ HttpClient = $Client; RequestTimeoutSeconds = 1 } @{
                Method = 'GET'; Uri = 'https://api.powerplatform.com/offline-test'
                Headers = @{ Authorization = 'Bearer synthetic' }; Body = $null
            }
        } $client
        Assert-Equal $response.StatusCode 200 'HTTP transport status'
        Assert-Equal $response.Body '{"value":[]}' 'HTTP response content'
        $handler.Slow = $true
        $watch = [Diagnostics.Stopwatch]::StartNew()
        Assert-Throws {
            & $module {
                param($Client)
                Invoke-HttpTransport @{ HttpClient = $Client; RequestTimeoutSeconds = 1 } @{
                    Method = 'GET'; Uri = 'https://api.powerplatform.com/offline-test'
                    Headers = @{}; Body = $null
                }
            } $client
        } 'canceled|cancelled'
        Assert-True ($watch.Elapsed.TotalSeconds -lt 3) 'Response body bypassed the request deadline'
    }
    finally { $client.Dispose() }
}

Invoke-Test 'Empty tenant has stable CSV schemas and zero counts' {
    $f = New-Fixture -Apps 0 -Environments 0
    $s = Invoke-Fixture $f
    Assert-Equal $s.ExitCode 0 'Empty scan should be complete'
    Assert-Equal $s.ReportedApps 0 'Empty app count'
    foreach ($name in @('AllApps.csv', 'PremiumApps.csv', 'ReviewApps.csv', 'Environments.csv', 'Coverage.csv', 'Failures.csv')) {
        Assert-True ([IO.File]::ReadAllText((Join-Path $f.Output $name)).StartsWith('"')) 'Missing CSV header'
    }
}

Invoke-Test 'A different tenant uses its own identity and tenant-bound queries without editing code' {
    $f = New-Fixture
    $f.Tenant = '99999999-9999-4999-8999-999999999999'
    $f.TokenTenant = $f.Tenant
    $s = Invoke-Fixture $f
    Assert-Equal $s.TenantId $f.Tenant 'The operator tenant was not propagated'
    Assert-Equal $s.ReportedApps 40 'Alternate tenant app count'
    Assert-ReportIds $f
}

Invoke-Test 'All app types, unpublished modules, owners, regions, and excluded environments' {
    $f = New-Fixture -Apps 100 -Environments 10 -PageSize 3
    $s = Invoke-Fixture $f
    Assert-Equal $s.ReportedApps 80 'Exact target app count'
    Assert-Equal $s.PremiumApps 64 'Exact premium app count'
    Assert-Equal $s.ReviewApps 16 'Exact unknown app count'
    Assert-Equal $s.ExitCode 2 'Unknown classification must require review'
    Assert-Equal $s.TargetEnvironments 8 'Target environments'
    Assert-ReportIds $f
    $rows = @(Import-Csv (Join-Path $f.Output 'AllApps.csv'))
    $model = $rows | Where-Object AppType -eq 'microsoft.powerapps/modeldrivenapps' | Select-Object -First 1
    Assert-Equal $model.OwnerStatus 'NotApplicable' 'Model-driven apps have no owner'
    Assert-True (@($rows | Where-Object PublicationState -eq 'Unpublished').Count -gt 0) 'Unpublished modules missing'
    $canvas = $rows | Where-Object AppType -eq 'microsoft.powerapps/canvasapps' | Select-Object -First 1
    Assert-Equal $canvas.OwnerEmail 'owner@example.invalid' 'Bulk owner metadata missing'
    Assert-True ($canvas.Sources -match 'AdminApps' -and $canvas.Sources -match 'InventoryApps') 'Bulk datasets were not reconciled'
    Assert-True ($canvas.CreatedUtc -match '^2026-01-01T00:00:00.*Z$') 'Timestamps must be ISO UTC, not culture-dependent strings'
    foreach ($column in @('TenantId', 'AppId', 'AppType', 'OwnerObjectId', 'EnvironmentId', 'ManagedState', 'PremiumClassification', 'PremiumEvidence', 'Sources', 'AppLink')) {
        Assert-True ($rows[0].PSObject.Properties.Name -contains $column) "Missing column $column"
    }
}

Invoke-Test 'Standard connector evidence is Unknown, never an invented standard flag' {
    $f = New-Fixture
    Invoke-Fixture $f | Out-Null
    $row = Import-Csv (Join-Path $f.Output 'AllApps.csv') | Where-Object AppId -eq (Get-TestAppId 9)
    Assert-Equal $row.PremiumClassification 'Unknown' 'Standard-only direct connectors cannot rule out premium flows'
}

Invoke-Test 'Bulk app and both Dataverse collections follow opaque next links across many pages' {
    $f = New-Fixture -Apps 100 -Environments 1 -PageSize 3
    $s = Invoke-Fixture $f
    Assert-Equal $s.ReportedApps 100 'Paged collection reconciliation count'
    Assert-Equal $s.PremiumApps 80 'Paged collection premium count'
    Assert-True ($f.Calls.AdminApps -gt 1) 'Admin app paging was not exercised'
    Assert-True ($f.Calls.DataversePublished -gt 1) 'Published model paging was not exercised'
    Assert-True ($f.Calls.DataverseUnpublished -gt 1) 'Unpublished model paging was not exercised'
    Assert-ReportIds $f
}

Invoke-Test 'Owner ID, display name, and email always come from the same authoritative bulk record' {
    $f = New-Fixture
    $f.Transform = {
        param($Kind, $Request, $Body, $Fixture)
        if ($Kind -eq 'AdminApps') {
            foreach ($row in $Body.value) {
                $row.properties.owner.id = '55555555-5555-4555-8555-555555555555'
                $row.properties.owner.displayName = 'New Synthetic Owner'
                $row.properties.owner.email = 'new-owner@example.invalid'
            }
        }
    }
    Invoke-Fixture $f | Out-Null
    $rows = @(Import-Csv (Join-Path $f.Output 'AllApps.csv') | Where-Object AppType -eq 'microsoft.powerapps/canvasapps')
    foreach ($row in $rows) {
        Assert-Equal $row.OwnerObjectId '55555555-5555-4555-8555-555555555555' 'Stale Inventory owner mixed with bulk owner'
        Assert-Equal $row.OwnerEmail 'new-owner@example.invalid' 'Bulk owner email'
    }
}

foreach ($headerCase in @(
    @{ Name = 'Retry-After seconds'; Headers = @{ 'Retry-After' = '2' }; Delay = 2000 },
    @{ Name = 'Retry-After HTTP-date'; Headers = @{ 'Retry-After' = 'Tue, 03 Nov 2026 15:00:03 GMT' }; Delay = 3000 },
    @{ Name = 'Vendor milliseconds and longest header'; Headers = @{ 'x-ms-retry-after-ms' = '4500'; 'Retry-After' = '1' }; Delay = 4500 }
)) {
    Invoke-Test $headerCase.Name {
        $f = New-Fixture -Apps 0 -Environments 0
        $f.Actions.Enqueue(@{ Kind = 'InventoryApps'; Status = 429; Headers = $headerCase.Headers })
        $s = Invoke-Fixture $f
        Assert-Equal $s.ExitCode 0 '429 should recover'
        Assert-True ($f.Sleeps.Contains([double]$headerCase.Delay)) 'Required backoff was not honored exactly'
        Assert-Equal $f.Calls.InventoryApps 2 '429 retry count'
    }
}

Invoke-Test 'Retry-After beyond budget stops without shortening or continuing elsewhere' {
    $f = New-Fixture
    $f.Budget = 1
    $f.Actions.Enqueue(@{ Kind = 'InventoryEnvironments'; Status = 429; Headers = @{ 'Retry-After' = '120' } })
    $s = Invoke-Fixture $f
    Assert-Equal $s.ExitCode 1 'Budget exhaustion must be incomplete'
    Assert-Equal $s.RequestsThisInvocation 1 'No request may bypass the server backoff'
    Assert-Equal $f.Sleeps.Count 0 'Do not shorten the requested wait'
}

Invoke-Test 'Network, 408, and retryable 5xx recover with finite exponential backoff' {
    $f = New-Fixture -Apps 0 -Environments 0
    $f.Actions.Enqueue(@{ Kind = 'InventoryApps'; Throw = [System.Net.Http.HttpRequestException]::new('synthetic') })
    $f.Actions.Enqueue(@{ Kind = 'InventoryApps'; Status = 408; Headers = @{} })
    $f.Actions.Enqueue(@{ Kind = 'InventoryApps'; Status = 503; Headers = @{} })
    $s = Invoke-Fixture $f
    Assert-Equal $s.ExitCode 0 'Transient failures should recover'
    Assert-Equal $f.Calls.InventoryApps 4 'Transient request count'
    Assert-True ($f.Sleeps[0] -ge 1000 -and $f.Sleeps[0] -le 2000) 'First fallback backoff range'
    Assert-True ($f.Sleeps[2] -ge 4000 -and $f.Sleeps[2] -le 5000) 'Exponential backoff range'
}

Invoke-Test 'Exhausted retry attempts retain partial output and failure status' {
    $f = New-Fixture -Apps 0 -Environments 0
    $f.MaxRetries = 1
    1..2 | ForEach-Object { $f.Actions.Enqueue(@{ Kind = 'InventoryApps'; Status = 500; Headers = @{} }) }
    $s = Invoke-Fixture $f
    Assert-Equal $s.ExitCode 1 'Exhausted retries cannot succeed'
    Assert-Equal $f.Calls.InventoryApps 2 'Retries must be bounded'
    Assert-Equal @(Import-Csv (Join-Path $f.Output 'Failures.csv')).Count 1 'Failure report count'
}

foreach ($status in @(400, 403, 404, 501, 505)) {
    Invoke-Test "Permanent HTTP $status is not retried" {
        $f = New-Fixture -Apps 0 -Environments 0
        $f.Actions.Enqueue(@{ Kind = 'InventoryApps'; Status = $status; Headers = @{} })
        $s = Invoke-Fixture $f
        Assert-Equal $s.ExitCode 1 'Permanent error cannot succeed'
        Assert-Equal $f.Calls.InventoryApps 1 'Permanent request was retried'
        Assert-True (-not [IO.File]::ReadAllText((Join-Path $f.Output 'Failures.csv')).Contains('synthetic-private-response-body')) 'Raw HTTP body leaked to disk'
    }
}

Invoke-Test '401 refreshes only once; repeated 401 cannot cause a refresh storm' {
    $f = New-Fixture -Apps 0 -Environments 0
    $f.Actions.Enqueue(@{ Kind = 'InventoryApps'; Status = 401; Headers = @{} })
    $s = Invoke-Fixture $f
    Assert-Equal $s.ExitCode 0 'One expired token should recover'
    Assert-Equal $f.TokenCalls['https://api.powerplatform.com'] 2 'Expected one forced refresh'
    $g = New-Fixture -Apps 0 -Environments 0
    1..2 | ForEach-Object { $g.Actions.Enqueue(@{ Kind = 'InventoryApps'; Status = 401; Headers = @{} }) }
    $s = Invoke-Fixture $g
    Assert-Equal $s.ExitCode 1 'Repeated 401 must fail'
    Assert-Equal $g.TokenCalls['https://api.powerplatform.com'] 2 'Refresh storm'
}

Invoke-Test 'A token losing its tenant-wide role stops instead of refreshing for every environment' {
    $f = New-Fixture -PageSize 2
    $f.Transform = {
        param($Kind, $Request, $Body, $Fixture)
        if ($Kind -eq 'InventoryEnvironments') {
            $Fixture.Role = 'no-longer-a-full-visibility-role'
            $Fixture.Now = $Fixture.Now.AddHours(2)
        }
    }
    $s = Invoke-Fixture $f
    Assert-Equal $s.ExitCode 1 'Lost role must stop the scan'
    Assert-Equal $s.RequestsThisInvocation 1 'Requests continued after role loss'
    Assert-Equal $f.TokenCalls['https://api.powerplatform.com'] 2 'Repeated role-loss refreshes'
}

Invoke-Test 'Long-running scans refresh expired tokens and apply request pacing' {
    $f = New-Fixture
    $f.Interval = 250
    $f.Transform = {
        param($Kind, $Request, $Body, $Fixture)
        if ($Kind -eq 'InventoryApps' -and $Fixture.Calls.InventoryApps -eq 1) {
            $Fixture.Now = $Fixture.Now.AddHours(2)
        }
    }
    Invoke-Fixture $f | Out-Null
    Assert-True ($f.TokenCalls['https://api.powerplatform.com'] -ge 2) 'Expired token was reused'
    Assert-True ($f.Sleeps.Contains([double]250)) 'Global pacing did not apply'
}

foreach ($authCase in @('tenant', 'role', 'app-only')) {
    Invoke-Test "Reject wrong token $authCase before discovery" {
        $f = New-Fixture
        switch ($authCase) {
            'tenant' { $f.TokenTenant = '99999999-9999-4999-8999-999999999999' }
            'role' { $f.Role = 'not-a-full-visibility-role' }
            'app-only' { $f.AppOnly = $true }
        }
        Assert-Throws { Invoke-Fixture $f } 'Token tenant|Full tenant visibility'
        Assert-Equal $f.Calls.Count 0 'Discovery occurred before authentication validation'
    }
}

Invoke-Test 'Missing continuation/truncation cannot be reported as a complete first page' {
    $f = New-Fixture
    $f.Transform = {
        param($Kind, $Request, $Body, $Fixture)
        if ($Kind -eq 'InventoryApps') { $Body.skipToken = ''; $Body.resultTruncated = 0 }
    }
    $s = Invoke-Fixture $f
    Assert-Equal $s.ExitCode 1 'Truncated first page was silently accepted'
}

Invoke-Test 'Repeated and cyclic continuation tokens are rejected' {
    foreach ($cycle in @($false, $true)) {
        $f = New-Fixture -PageSize 2
        $f.Cycle = $cycle; $f.FirstToken = ''
        $f.Transform = {
            param($Kind, $Request, $Body, $Fixture)
            if ($Kind -eq 'InventoryApps') {
                if ($Fixture.Calls.InventoryApps -eq 1) { $Fixture.FirstToken = $Body.skipToken }
                if (-not $Fixture.Cycle -and $Fixture.Calls.InventoryApps -eq 2) {
                    $Body.skipToken = $Request.Body.Options.SkipToken
                }
                if ($Fixture.Cycle -and $Fixture.Calls.InventoryApps -eq 3) { $Body.skipToken = $Fixture.FirstToken }
            }
        }
        $s = Invoke-Fixture $f
        Assert-Equal $s.ExitCode 1 'Repeated/cyclic cursor must be incomplete'
        Assert-True ($f.Calls.InventoryApps -le 3) 'Pagination did not terminate'
    }
}

Invoke-Test 'Repeated IDs, count mismatch, and missing response arrays fail explicitly' {
    foreach ($mutation in @('id', 'count', 'array')) {
        $f = New-Fixture
        $f.Mutation = $mutation
        $f.Transform = {
            param($Kind, $Request, $Body, $Fixture)
            if ($Kind -eq 'InventoryApps') {
                switch ($Fixture.Mutation) {
                    'id' { if ($Body.data.Count -gt 1) { $Body.data[1].id = $Body.data[0].id } }
                    'count' { $Body.count++ }
                    'array' { $Body.Remove('data') }
                }
            }
        }
        Assert-Equal (Invoke-Fixture $f).ExitCode 1 'Malformed pagination was accepted'
    }
}

Invoke-Test 'Cross-origin continuation URLs are rejected without sending a token there' {
    $f = New-Fixture -PageSize 2
    $f.Transform = {
        param($Kind, $Request, $Body, $Fixture)
        if ($Kind -eq 'AdminApps') { $Body.nextLink = 'https://outside.example.invalid/steal' }
    }
    $s = Invoke-Fixture $f
    Assert-Equal $s.ExitCode 1 'Unsafe continuation URL was accepted'
}

Invoke-Test 'Cross-tenant data, denied environments, and missing Dataverse URLs stay incomplete' {
    $f = New-Fixture
    $f.Transform = {
        param($Kind, $Request, $Body, $Fixture)
        if ($Kind -eq 'InventoryApps' -and $Body.data.Count -gt 0) {
            $Body.data[0].tenantId = '99999999-9999-4999-8999-999999999999'
        }
    }
    Assert-Equal (Invoke-Fixture $f).ExitCode 1 'Cross-tenant row accepted'
    $g = New-Fixture
    $g.Actions.Enqueue(@{ Kind = 'AdminApps'; Status = 403; Headers = @{} })
    $g.MissingUrlEnvironment = 2
    $s = Invoke-Fixture $g
    Assert-Equal $s.ExitCode 1 'Inaccessible environments cannot produce success'
    Assert-True ($s.ReportedApps -gt 0) 'Useful partial rows were lost'
    Assert-Equal @(Import-Csv (Join-Path $g.Output 'Failures.csv')).Count 2 'Explicit environment failures missing'
}

Invoke-Test 'Unknown managed state stays Review and never enters the target premium report' {
    $f = New-Fixture
    $f.UnknownEnvironment = 1
    $s = Invoke-Fixture $f
    Assert-Equal $s.ReviewEnvironments 1 'Unknown environment was silently excluded'
    $rows = @(Import-Csv (Join-Path $f.Output 'PremiumApps.csv') | Where-Object EnvironmentId -eq (Get-TestEnvironmentId 1))
    Assert-Equal $rows.Count 0 'Unknown managed state was coerced to unmanaged'
}

Invoke-Test 'Missing environment joins and changed environment scope never silently succeed' {
    foreach ($mutation in @('join', 'scope')) {
        $f = New-Fixture -Apps 100 -Environments 10
        $f.Mutation = $mutation
        $f.Transform = {
            param($Kind, $Request, $Body, $Fixture)
            if ($Kind -eq 'InventoryApps') {
                foreach ($row in $Body.data) {
                    if ($Fixture.Mutation -eq 'join' -and
                        $row.properties.environmentId -eq (Get-TestEnvironmentId 1)) {
                        $row.Remove('environmentType'); $row.Remove('isManagedEnvironment')
                    }
                    if ($Fixture.Mutation -eq 'scope' -and
                        $row.properties.environmentId -eq (Get-TestEnvironmentId 9)) {
                        $row.isManagedEnvironment = $false
                    }
                }
            }
        }
        $s = Invoke-Fixture $f
        Assert-Equal $s.ExitCode 2 'Missing/different environment metadata must require review'
        $environmentId = Get-TestEnvironmentId $(if ($mutation -eq 'join') { 1 } else { 9 })
        $rows = @(Import-Csv (Join-Path $f.Output 'PremiumApps.csv') | Where-Object EnvironmentId -eq $environmentId)
        if ($mutation -eq 'join') {
            $rows = @($rows | Where-Object Sources -match 'InventoryApps')
        }
        Assert-Equal $rows.Count 0 'Unconfirmed environment was included in primary premium report'
    }
}

Invoke-Test 'Duplicate logical IDs inside one source are deduplicated and require review' {
    $f = New-Fixture
    $f.Transform = {
        param($Kind, $Request, $Body, $Fixture)
        if ($Kind -eq 'AdminApps' -and $Body.value.Count -gt 1) {
            $Body.value[1].name = $Body.value[0].name
        }
    }
    $s = Invoke-Fixture $f
    Assert-Equal $s.ExitCode 2 'Repeated logical app IDs should require review'
    Assert-True (@(Import-Csv (Join-Path $f.Output 'ReviewApps.csv') |
        Where-Object PremiumEvidence -match 'same source repeated').Count -gt 0) 'Repeated ID evidence missing'
    Assert-ReportIds $f
}

Invoke-Test 'Inventory drift is visible and nonzero even when pagination terminates' {
    $f = New-Fixture
    $f.Transform = {
        param($Kind, $Request, $Body, $Fixture)
        if ($Kind -eq 'InventoryApps' -and $Fixture.Calls.InventoryApps -eq 2) { $Body.totalRecords++ }
    }
    $s = Invoke-Fixture $f
    Assert-Equal $s.UnstableSources 1 'Count drift not recorded'
    Assert-Equal $s.ExitCode 2 'Drift must require review'
}

Invoke-Test 'CSV quotes, newlines, and spreadsheet formulas are safe' {
    $f = New-Fixture
    $f.Transform = {
        param($Kind, $Request, $Body, $Fixture)
        if ($Kind -eq 'InventoryApps' -and $Body.data.Count -gt 0) { $Body.data[0].properties.displayName = "=1+1`n`"quoted`"" }
    }
    Invoke-Fixture $f | Out-Null
    $row = Import-Csv (Join-Path $f.Output 'AllApps.csv') | Where-Object AppId -eq (Get-TestAppId 1)
    Assert-True ($row.AppName.StartsWith("'=")) 'CSV formula not neutralized'
    Assert-True ($row.AppName.Contains("`n") -and $row.AppName.Contains('"quoted"')) 'CSV content was not round-tripped'
}

Invoke-Test 'An exclusive output lock prevents concurrent runs' {
    $f = New-Fixture
    [IO.Directory]::CreateDirectory($f.Output) | Out-Null
    $lock = [IO.File]::Open((Join-Path $f.Output '.inventory.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { Assert-Throws { Invoke-Fixture $f } 'being used by another process|sharing|access' }
    finally { $lock.Dispose() }
}

Invoke-Test 'Resume rejects tenant/page-size mismatch, changed reports, and corrupt committed pages' {
    foreach ($mutation in @('tenant', 'size', 'report', 'journal', 'cursor')) {
        $f = New-Fixture
        Invoke-Fixture $f | Out-Null
        switch ($mutation) {
            'tenant' { $f.Tenant = '99999999-9999-4999-8999-999999999999' }
            'size' { $f.PageSize++ }
            'report' { [IO.File]::AppendAllText((Join-Path $f.Output 'AllApps.csv'), 'changed') }
            'journal' {
                $path = [IO.Directory]::EnumerateFiles((Join-Path $f.Output '.sources'), '*.ndjson', [IO.SearchOption]::AllDirectories) | Select-Object -First 1
                [IO.File]::AppendAllText($path, 'changed')
            }
            'cursor' {
                $path = [IO.Directory]::EnumerateFiles((Join-Path $f.Output '.sources'), 'state.json', [IO.SearchOption]::AllDirectories) | Select-Object -First 1
                $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
                $state.Cursor = 'corrupt'
                [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $state -Depth 40 -Compress))
            }
        }
        Assert-Throws { Invoke-Fixture $f -Resume } 'does not match|changed or lost|integrity|cursor|do not agree'
    }
}

Invoke-Test 'Interrupted page commit resumes without duplicates or skipped IDs' {
    foreach ($event in @('BeforeCheckpoint', 'AfterCheckpoint')) {
        $f = New-Fixture -Apps 100 -Environments 10 -PageSize 3
        $f.Event = $event
        $f.FaultHook = {
            param($Event, $Spec, $Page)
            if ($Event -eq $f.Event -and $Spec.Kind -eq 'InventoryApps' -and $Page -eq 3) {
                throw [OperationCanceledException]::new('synthetic interruption')
            }
        }.GetNewClosure()
        Assert-Throws { Invoke-Fixture $f } 'synthetic interruption'
        $calls = $f.Calls.InventoryEnvironments
        $f.FaultHook = $null
        $s = Invoke-Fixture $f -Resume
        Assert-Equal $s.ReportedApps 80 'Resume app count'
        Assert-Equal $f.Calls.InventoryEnvironments $calls 'Completed source downloaded again'
        Assert-ReportIds $f
    }
}

Invoke-Test 'Source fingerprints and resume work across separate PowerShell processes' {
    $probeRoot = Join-Path $testRoot 'cross-process'
    $executable = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    & $executable -NoLogo -NoProfile -File $PSCommandPath -ProcessProbe Create -OutputDirectory $probeRoot
    Assert-Equal $LASTEXITCODE 0 'Cross-process initial checkpoint'
    & $executable -NoLogo -NoProfile -File $PSCommandPath -ProcessProbe Resume -OutputDirectory $probeRoot
    Assert-Equal $LASTEXITCODE 0 'Cross-process resume failed'
}

Invoke-Test 'Resume retries only incomplete sources and never persists tokens' {
    $f = New-Fixture
    $f.Actions.Enqueue(@{ Kind = 'AdminApps'; Status = 403; Headers = @{} })
    Assert-Equal (Invoke-Fixture $f).ExitCode 1 'Initial failure status'
    $inventoryCalls = $f.Calls.InventoryApps
    $s = Invoke-Fixture $f -Resume
    Assert-Equal $s.IncompleteSources 0 'Incomplete source did not recover'
    Assert-Equal $f.Calls.InventoryApps $inventoryCalls 'Completed app inventory was re-requested'
    foreach ($path in [IO.Directory]::EnumerateFiles($f.Output, '*', [IO.SearchOption]::AllDirectories)) {
        if ([IO.Path]::GetFileName($path) -ne '.inventory.lock') {
            Assert-True (-not [IO.File]::ReadAllText($path).Contains('synthetic-not-a-credential')) 'Access token persisted'
        }
    }
}

if (-not $SkipScale) {
    Invoke-Test "Paged end-to-end $ScaleApps apps / 250 environments, interruption and resume" {
        $f = New-Fixture -Apps $ScaleApps -Environments 250 -PageSize 1000
        $f.FaultHook = {
            param($Event, $Spec, $Page)
            if ($Event -eq 'BeforeCheckpoint' -and $Spec.Kind -eq 'InventoryApps' -and $Page -eq 3) {
                throw [OperationCanceledException]::new('synthetic scale interruption')
            }
        }
        Assert-Throws { Invoke-Fixture $f } 'synthetic scale interruption'
        $f.FaultHook = $null
        $s = Invoke-Fixture $f -Resume
        Assert-Equal $s.ReportedApps ([long]($ScaleApps * 0.8)) 'Exact scale report count'
        Assert-Equal $s.PremiumApps ([long]($ScaleApps * 0.64)) 'Exact scale premium count'
        Assert-Equal $s.ReviewApps ([long]($ScaleApps * 0.16)) 'Exact scale review count'
        Assert-Equal $s.Environments 250 'Exact scale environment count'
        Assert-Equal $s.IncompleteSources 0 'Scale source failures'
        Assert-ReportIds $f
        $scaleEvidence = @{
            SyntheticApps = $ScaleApps; Environments = 250
            ReportedApps = $s.ReportedApps; PremiumApps = $s.PremiumApps; ReviewApps = $s.ReviewApps
            IncompleteSources = $s.IncompleteSources; Calls = $f.Calls
            PeakWorkingSetBytes = [Diagnostics.Process]::GetCurrentProcess().PeakWorkingSet64
            Output = $f.Output; LiveTenantTested = $false
        }
        [IO.File]::WriteAllText((Join-Path $testRoot 'scale-evidence.json'), (ConvertTo-Json -InputObject $scaleEvidence -Depth 10))
    }
}

$failed = @($results | Where-Object { -not $_.Passed }).Count
$evidence = @{
    Passed = $results.Count - $failed; Failed = $failed
    Seconds = $timer.Elapsed.TotalSeconds; ScaleSkipped = [bool]$SkipScale
    LiveTenantTested = $false; Tests = $results.ToArray()
}
[IO.File]::WriteAllText((Join-Path $testRoot 'test-results.json'), (ConvertTo-Json -InputObject $evidence -Depth 10))
Write-Host "$($evidence.Passed) passed, $failed failed; $([Math]::Round($timer.Elapsed.TotalSeconds, 2)) seconds"
Write-Host "Evidence: $testRoot"
if (-not $KeepOutput -and $failed -eq 0) {
    foreach ($path in [IO.Directory]::EnumerateDirectories($testRoot)) {
        [IO.Directory]::Delete($path, $true)
    }
}
if ($failed -gt 0) { exit 1 }
exit 0

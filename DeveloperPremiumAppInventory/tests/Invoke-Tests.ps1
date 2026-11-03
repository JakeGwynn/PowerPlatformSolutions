#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$SkipScale,
    [ValidateRange(100000, 1000000)][int]$ScaleApps = 100000,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\.test-output'),
    [switch]$KeepOutput,
    [ValidateSet('', 'Create', 'Resume')][string]$ProcessProbe = '',
    [string]$OtherPowerShellPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\Inventory.psm1') -Force
$module = Get-Module Inventory
$testRoot = Join-Path ([System.IO.Path]::GetFullPath($OutputDirectory)) ([guid]::NewGuid().ToString())
[System.IO.Directory]::CreateDirectory($testRoot) | Out-Null
$testDataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ppi-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
if ([System.IO.Directory]::Exists($testDataRoot)) { throw 'The temporary test data directory already exists.' }
[System.IO.Directory]::CreateDirectory($testDataRoot) | Out-Null
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
        Output = Join-Path $testDataRoot ([guid]::NewGuid().ToString())
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
    if ($Fixture.ContainsKey('NativeOptions')) {
        $arguments.Remove('TokenProvider')
        foreach ($key in $Fixture.NativeOptions.Keys) { $arguments[$key] = $Fixture.NativeOptions[$key] }
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
    [IO.Directory]::Delete($testDataRoot, $true)
    exit 0
}

Invoke-Test 'Public command exposes its synopsis, parameters, and runnable help examples' {
    $scriptPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Get-UnmanagedDeveloperPremiumApps.ps1'))
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
    $help = $ast.GetHelpContent()
    Assert-True ($null -ne $help) 'PowerShell did not recognize the comment-based help'
    Assert-True ($help.Synopsis -match 'unmanaged Developer') 'Missing public synopsis'
    Assert-Equal @($help.Examples).Count 3 'Missing secret/certificate/delegated invocation examples'
    foreach ($example in (Get-Help $scriptPath -Full).examples.example) {
        $rendered = $example.code + ' ' + (@($example.remarks | ForEach-Object Text) -join ' ')
        Assert-True ($rendered -match '(powershell\.exe|pwsh) -File |Get-UnmanagedDeveloperPremiumApps\.ps1') 'PowerShell help truncated the invocation example'
    }
}

Invoke-Test 'Portable JSON preserves nested arrays, nulls, booleans, and literal Unicode escapes' {
    $json = '{"empty":[],"one":[{"nested":[false,null]}],"stamp":"2026-01-01T00:00:00Z","text":"\u0027<tag>&\u0027","literal":"\\u0027","slashes":"\\\\\u0027"}'
    $value = & $module { param($Json) ConvertFrom-InventoryJson $Json } $json
    Assert-True ($value -is [Collections.IDictionary]) 'JSON objects must be dictionaries'
    Assert-Equal $value.empty.Count 0 'Empty JSON array was lost'
    Assert-Equal $value.one.Count 1 'Singleton JSON array was flattened'
    Assert-Equal $value.one[0].nested.Count 2 'Nested JSON array was lost'
    Assert-Equal $value.one[0].nested[0] $false 'JSON boolean was changed'
    Assert-True ($null -eq $value.one[0].nested[1]) 'JSON null was changed'
    Assert-Equal $value.literal '\u0027' 'Literal escape text was decoded twice'
    $roundTrip = & $module {
        param($Value)
        ConvertFrom-InventoryJson (ConvertTo-InventoryJson $Value)
    } $value
    Assert-Equal $roundTrip.literal $value.literal 'JSON serialization changed literal escape text'
    Assert-Equal $roundTrip.slashes $value.slashes 'Escaped backslashes changed during serialization'
    Assert-Equal $roundTrip.text $value.text 'HTML/single-quote escape normalization changed text'
    $expectedCanonical = '{"empty":[],"text":"single ''quote'' <tag> & double \"quote\""}'
    $digests = & $module {
        param($Expected)
        @{
            Expected = Get-Sha256 $Expected
            Actual = Get-ObjectDigest @{ text = 'single ''quote'' <tag> & double "quote"'; empty = @() }
        }
    } $expectedCanonical
    Assert-Equal $digests.Actual $digests.Expected 'Canonical source hashes differ from the existing PowerShell 7 encoding'
}

Invoke-Test 'Portable hashing and atomic replacement preserve committed files' {
    $path = Join-Path $testRoot 'atomic-compatibility.txt'
    $values = & $module {
        param($Path)
        Write-AtomicText $Path 'abc'
        $first = Get-FileDigest $Path
        Write-AtomicText $Path 'replacement'
        @{ First = $first; Empty = Get-Sha256 ''; Actual = [IO.File]::ReadAllText($Path) }
    } $path
    Assert-Equal $values.First 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' 'SHA-256 file hash changed'
    Assert-Equal $values.Empty 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' 'Empty text hash changed'
    Assert-Equal $values.Actual 'replacement' 'Existing atomic file was not replaced'
    Assert-True (-not [IO.File]::Exists("$path.pending")) 'Atomic replacement left an uncommitted temporary file'
}

Invoke-Test 'The bounded portable merge retains identical lines from different input files' {
    $directory = Join-Path $testRoot 'merge-compatibility'
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $first = Join-Path $directory 'first.txt'
    $second = Join-Path $directory 'second.txt'
    $output = Join-Path $directory 'merged.txt'
    [IO.File]::WriteAllLines($first, [string[]]@('a', 'b', 'c'))
    [IO.File]::WriteAllLines($second, [string[]]@('a', 'b', 'd'))
    & $module { param($Paths, $Output) Merge-RunFiles $Paths $Output } ([string[]]@($first, $second)) $output
    Assert-Equal ([IO.File]::ReadAllLines($output) -join ',') 'a,a,b,b,c,d' 'Portable merge dropped duplicate lines or changed ordering'
}

Invoke-Test 'Actual HTTP transport reads content and enforces a response-body timeout' {
    $compilerArguments = @{
        TypeDefinition = @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Collections.Generic;
using System.Text;
using System.Threading;

public sealed class NativeInventoryTestServer : IDisposable
{
    private readonly TcpListener listener;
    private readonly Thread worker;
    private TcpClient connection;
    public string Uri { get; private set; }
    public bool Slow;
    public int StatusCode = 200;
    public string Body = "{\"value\":[]}";
    public string RequestBody;
    public readonly Dictionary<string, string> Headers = new Dictionary<string, string>();
    public NativeInventoryTestServer()
    {
        listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        Uri = "http://127.0.0.1:" + ((IPEndPoint)listener.LocalEndpoint).Port + "/";
        worker = new Thread(Serve);
        worker.IsBackground = true;
    }
    public void Start() { worker.Start(); }
    public static Thread PostAuthForm(string target, string form)
    {
        Thread sender = new Thread(delegate()
        {
            System.Uri uri = new System.Uri(target);
            using (TcpClient client = new TcpClient(uri.Host, uri.Port))
            using (NetworkStream stream = client.GetStream())
            {
                byte[] body = Encoding.UTF8.GetBytes(form);
                byte[] headers = Encoding.ASCII.GetBytes("POST " + uri.AbsolutePath +
                    " HTTP/1.1\r\nHost: " + uri.Authority +
                    "\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: " + body.Length +
                    "\r\nConnection: close\r\n\r\n");
                stream.Write(headers, 0, headers.Length);
                stream.Write(body, 0, body.Length);
                stream.ReadTimeout = 5000;
                byte[] response = new byte[1024];
                stream.Read(response, 0, response.Length);
            }
        });
        sender.IsBackground = true;
        sender.Start();
        return sender;
    }
    private void Serve()
    {
        try
        {
            connection = listener.AcceptTcpClient();
            using (connection)
            using (NetworkStream stream = connection.GetStream())
            {
                stream.ReadTimeout = 5000;
                StreamReader reader = new StreamReader(stream, Encoding.UTF8, false, 1024, true);
                string line = reader.ReadLine();
                int length = 0;
                while (!String.IsNullOrEmpty(line = reader.ReadLine()))
                {
                    if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase))
                        length = Int32.Parse(line.Substring(15).Trim());
                    if (line.StartsWith("Expect:", StringComparison.OrdinalIgnoreCase))
                    {
                        byte[] interim = Encoding.ASCII.GetBytes("HTTP/1.1 100 Continue\r\n\r\n");
                        stream.Write(interim, 0, interim.Length);
                    }
                }
                char[] request = new char[length];
                int offset = 0;
                while (offset < length)
                {
                    int read = reader.Read(request, offset, length - offset);
                    if (read == 0) break;
                    offset += read;
                }
                RequestBody = new String(request, 0, offset);
                byte[] body = Encoding.UTF8.GetBytes(Body);
                StringBuilder header = new StringBuilder("HTTP/1.1 " + StatusCode +
                    " Result\r\nContent-Type: application/json; charset=utf-8\r\nConnection: close\r\nContent-Length: " + body.Length + "\r\n");
                foreach (KeyValuePair<string, string> item in Headers)
                    header.Append(item.Key + ": " + item.Value + "\r\n");
                header.Append("\r\n");
                byte[] headerBytes = Encoding.ASCII.GetBytes(header.ToString());
                stream.Write(headerBytes, 0, headerBytes.Length);
                if (Slow)
                {
                    for (int i = 0; i < body.Length; i++)
                    {
                        stream.Write(body, i, 1);
                        stream.Flush();
                        Thread.Sleep(400);
                    }
                }
                else stream.Write(body, 0, body.Length);
            }
        }
        catch (IOException) { }
        catch (SocketException) { }
        catch (ObjectDisposedException) { }
    }
    public void Dispose()
    {
        listener.Stop();
        if (connection != null) connection.Close();
        if (worker.IsAlive) worker.Join(2000);
    }
}
'@
    }
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        $compilerArguments.ReferencedAssemblies = @('System.dll', 'System.Core.dll')
    }
    Add-Type @compilerArguments
    $server = [NativeInventoryTestServer]::new()
    $server.Start()
    $session = @{ RequestTimeoutSeconds = 5; NativeWebRunner = $null }
    try {
        $response = & $module {
            param($Session, $Uri)
            Invoke-HttpTransport $Session @{
                Method = 'GET'; Uri = $Uri
                Headers = @{ Accept = 'application/json' }; Body = $null
            }
        } $session $server.Uri
        Assert-Equal $response.StatusCode 200 'HTTP transport status'
        Assert-Equal $response.Body '{"value":[]}' 'HTTP response content'
    }
    finally { $server.Dispose(); if ($null -ne $session.NativeWebRunner) { $session.NativeWebRunner.Dispose() } }
    $server = [NativeInventoryTestServer]::new()
    $server.Slow = $true
    $server.Start()
    $session = @{ RequestTimeoutSeconds = 1; NativeWebRunner = $null }
    try {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        Assert-Throws {
            & $module {
                param($Session, $Uri)
                Invoke-HttpTransport $Session @{ Method = 'GET'; Uri = $Uri; Headers = @{}; Body = $null }
            } $session $server.Uri
        } 'deadline|timed out|web request failed'
        Assert-True ($watch.Elapsed.TotalSeconds -lt 3) 'Native response body bypassed the whole-request deadline'
    }
    finally { $server.Dispose(); if ($null -ne $session.NativeWebRunner) { $session.NativeWebRunner.Dispose() } }
}

Invoke-Test 'Native web cmdlets retain 429 headers and keep sensitive token responses off disk' {
    $server = [NativeInventoryTestServer]::new()
    $server.StatusCode = 429
    $server.Headers.Add('Retry-After', '3')
    $server.Start()
    $session = @{ RequestTimeoutSeconds = 5; NativeWebRunner = $null }
    try {
        $response = & $module {
            param($Session, $Uri)
            Invoke-HttpTransport $Session @{ Method = 'GET'; Uri = $Uri; Headers = @{}; Body = $null }
        } $session $server.Uri
        Assert-Equal $response.StatusCode 429 'Native HTTP failure status was lost'
        Assert-Equal $response.Headers['Retry-After'] '3' 'Native throttling header was lost'
    }
    finally { $server.Dispose(); if ($null -ne $session.NativeWebRunner) { $session.NativeWebRunner.Dispose() } }
    $server = [NativeInventoryTestServer]::new()
    $server.Body = '{"access_token":"synthetic-private-token"}'
    $server.Start()
    $session = @{ RequestTimeoutSeconds = 5; NativeWebRunner = $null }
    try {
        $response = & $module {
            param($Session, $Uri)
            Invoke-HttpTransport $Session @{
                Method = 'POST'; Uri = $Uri; Headers = @{}
                Body = 'client_secret=synthetic%26secret'; ContentType = 'application/x-www-form-urlencoded'; Sensitive = $true
            }
        } $session $server.Uri
        Assert-Equal $response.Body $server.Body 'Sensitive response content was lost'
        Assert-Equal $server.RequestBody 'client_secret=synthetic%26secret' 'Native form body encoding was changed'
        Assert-Equal $session.NativeWebRunner.Commands.Commands.Count 0 'Native request parameters were left in the reusable runspace'
        Assert-Equal $session.NativeWebRunner.Streams.Error.Count 0 'Raw native web errors were retained'
    }
    finally { $server.Dispose(); if ($null -ne $session.NativeWebRunner) { $session.NativeWebRunner.Dispose() } }
}

Invoke-Test 'Native loopback callback receives a form-post code without launching a real browser' {
    $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $probe.Start()
    $port = $probe.LocalEndpoint.Port
    $probe.Stop()
    $authorization = @{
        Uri = 'https://login.microsoftonline.com/synthetic'
        RedirectUri = "http://127.0.0.1:$port/"; State = 'synthetic-state'
    }
    $holder = @{ Thread = $null }
    $launcher = {
        param($Uri)
        $holder.Thread = [NativeInventoryTestServer]::PostAuthForm(
            $authorization.RedirectUri, 'code=synthetic-code&state=synthetic-state')
    }.GetNewClosure()
    try {
        $result = & $module {
            param($Authorization, $Launcher)
            Receive-AuthCode $Authorization 30 -BrowserLauncher $Launcher
        } $authorization $launcher
        Assert-Equal $result.Code 'synthetic-code' 'Native form-post callback code'
        Assert-Equal $result.State 'synthetic-state' 'Native form-post callback state'
    }
    finally { if ($null -ne $holder.Thread) { $holder.Thread.Join(2000) | Out-Null } }
}

function New-NativeFixtureOptions {
    param($Fixture, [string]$Mode = 'ClientSecret', $Certificate)
    $Fixture.AuthCalls = [Collections.Generic.List[object]]::new()
    $Fixture.AuthChallenges = [Collections.Generic.List[string]]::new()
    $receiver = {
        param($Authorization, $Timeout)
        $query = & $module { param($Text) ConvertFrom-FormBody $Text } ([Uri]$Authorization.Uri).Query.TrimStart('?')
        Assert-Equal $query.response_mode 'form_post' 'Authorization code should not be placed in browser URL history'
        Assert-Equal $query.code_challenge_method 'S256' 'PKCE challenge method'
        Assert-Equal $query.redirect_uri 'http://localhost:8400/' 'Native redirect URI'
        Assert-True ($query.scope -match 'offline_access') 'Offline access was not requested'
        $Fixture.AuthChallenges.Add($query.code_challenge)
        return @{ Code = 'synthetic-code'; State = $Authorization.State }
    }.GetNewClosure()
    $tokenRequest = {
        param($Request)
        Assert-True $Request.Sensitive 'Token response must remain in memory'
        Assert-True ($Request.Uri -eq "https://login.microsoftonline.com/$($Fixture.Tenant)/oauth2/v2.0/token") 'Token authority was not tenant-bound'
        $form = & $module { param($Text) ConvertFrom-FormBody $Text } $Request.Body
        Assert-True ($form.grant_type -in @('authorization_code', 'refresh_token')) 'Native mode attempted unsupported app-only client credentials'
        if ($form.grant_type -eq 'authorization_code') {
            $challenge = & $module { param($Verifier) Get-AuthPkceChallenge $Verifier } $form.code_verifier
            Assert-True ($Fixture.AuthChallenges.Contains($challenge)) 'PKCE verifier did not match the browser challenge'
        }
        if ($Mode -eq 'ClientSecret') {
            Assert-Equal $form.client_secret 'synthetic&secret+with spaces' 'Secure secret form encoding'
        }
        else {
            Assert-Equal $form.client_assertion_type 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer' 'Certificate assertion type'
            $claims = & $module { param($Token) Read-TokenClaims $Token } $form.client_assertion
            Assert-Equal $claims.aud $Request.Uri 'Certificate assertion audience'
            Assert-Equal $claims.iss 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' 'Certificate client identity'
            Assert-True ($claims.exp - $claims.iat -le 300) 'Certificate assertion is too long-lived'
            $segments = $form.client_assertion.Split('.')
            $payload = $segments[2].Replace('-', '+').Replace('_', '/')
            $payload = $payload.PadRight($payload.Length + ((4 - $payload.Length % 4) % 4), '=')
            $signature = [Convert]::FromBase64String($payload)
            $publicKey = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($Certificate)
            try {
                Assert-True ($publicKey.VerifyData([Text.Encoding]::UTF8.GetBytes($segments[0] + '.' + $segments[1]),
                    $signature, [Security.Cryptography.HashAlgorithmName]::SHA256,
                    [Security.Cryptography.RSASignaturePadding]::Pss)) 'Certificate assertion signature did not verify'
            }
            finally { $publicKey.Dispose() }
        }
        $Fixture.AuthCalls.Add(@{ Grant = $form.grant_type; Scope = $form.scope })
        $audience = $form.scope -replace '/\.default$', ''
        return @{
            StatusCode = 200; Headers = @{}
            Body = ConvertTo-Json -Compress -InputObject @{
                token_type = 'Bearer'; access_token = New-TestToken $Fixture $audience
                refresh_token = 'synthetic-refresh-token'
            }
        }
    }.GetNewClosure()
    $options = @{
        AuthenticationMode = $Mode; ClientId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        AuthCodeReceiver = $receiver; AuthTokenRequest = $tokenRequest
    }
    if ($Mode -eq 'ClientSecret') {
        $options.ClientSecret = ConvertTo-SecureString 'synthetic&secret+with spaces' -AsPlainText -Force
    }
    else { $options.ClientCertificate = $Certificate }
    return $options
}

Invoke-Test 'Native secret authentication runs the full inventory without Az.Accounts and refreshes across audiences' {
    $f = New-Fixture
    $f.NativeOptions = New-NativeFixtureOptions $f
    $s = Invoke-Fixture $f
    Assert-Equal $s.AuthenticationMode 'ClientSecret' 'Reported authentication mode'
    Assert-Equal $s.ReportedApps 40 'Native secret inventory count'
    Assert-Equal $f.AuthCalls[0].Grant 'authorization_code' 'Initial delegated grant'
    Assert-True (@($f.AuthCalls | Where-Object Grant -eq 'refresh_token').Count -gt 0) 'Native tokens were not refreshed for Dataverse'
    Assert-Equal $f.AuthChallenges.Count 1 'Native mode repeatedly prompted instead of refreshing'
    Assert-True ($null -eq (Get-Module Az.Accounts)) 'Native authentication imported Az.Accounts'
    Assert-ReportIds $f
    foreach ($path in [IO.Directory]::EnumerateFiles($f.Output, '*', [IO.SearchOption]::AllDirectories)) {
        if ([IO.Path]::GetFileName($path) -ne '.inventory.lock') {
            $text = [IO.File]::ReadAllText($path)
            Assert-True ($text -notmatch 'synthetic&secret|synthetic-refresh-token|synthetic-code|synthetic-not-a-credential') 'Native credential/code/token persisted in a report or checkpoint'
        }
    }
    Assert-True ($f.NativeOptions.ClientSecret.Length -gt 0) 'The caller-owned SecureString was disposed'
}

Invoke-Test 'Native certificate authentication signs verifiable short-lived PS256 assertions without Az.Accounts' {
    $f = New-Fixture
    $key = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        [Security.Cryptography.RSACng]::new(2048)
    } else { [Security.Cryptography.RSA]::Create(2048) }
    $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=Synthetic inventory test',
        $key, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pss)
    $certificate = $request.CreateSelfSigned($f.Now.AddDays(-1), $f.Now.AddDays(2))
    try {
        $f.NativeOptions = New-NativeFixtureOptions $f -Mode Certificate -Certificate $certificate
        $s = Invoke-Fixture $f
        Assert-Equal $s.AuthenticationMode 'Certificate' 'Reported certificate mode'
        Assert-Equal $s.ReportedApps 40 'Native certificate inventory count'
        Assert-True ($f.AuthCalls.Count -gt 1) 'Certificate refresh flow was not exercised'
        Assert-True ($null -eq (Get-Module Az.Accounts)) 'Certificate mode imported Az.Accounts'
        Assert-ReportIds $f
    }
    finally { $certificate.Dispose(); $key.Dispose() }
}

Invoke-Test 'Native authentication rejects mismatched callback state, missing credentials, and public redirect URLs' {
    $f = New-Fixture
    $f.NativeOptions = New-NativeFixtureOptions $f
    $f.NativeOptions.AuthCodeReceiver = { @{ Code = 'synthetic-code'; State = 'wrong-state' } }
    Assert-Throws { Invoke-Fixture $f } 'state or code validation'
    Assert-Equal $f.AuthCalls.Count 0 'A mismatched code was sent to Microsoft'
    $g = New-Fixture
    $g.NativeOptions = New-NativeFixtureOptions $g
    $g.NativeOptions.RedirectUri = 'http://outside.example.invalid/'
    Assert-Throws { Invoke-Fixture $g } 'loopback'
    $h = New-Fixture
    $h.NativeOptions = New-NativeFixtureOptions $h
    $h.NativeOptions.ClientSecret = $null
    Assert-Throws { Invoke-Fixture $h } 'SecureString client secret'
}

Invoke-Test 'Native token errors are permanent when appropriate and never expose credential response bodies' {
    $f = New-Fixture
    $f.NativeOptions = New-NativeFixtureOptions $f
    $calls = @{ Count = 0 }
    $f.NativeOptions.AuthTokenRequest = {
        param($Request)
        $calls.Count++
        return @{ StatusCode = 400; Headers = @{}; Body = '{"error_description":"synthetic-private-credential"}' }
    }.GetNewClosure()
    Assert-Throws { Invoke-Fixture $f } 'token request failed \(HTTP 400\)'
    Assert-Equal $calls.Count 1 'Permanent credential error was retried'
    Assert-True (-not [IO.File]::ReadAllText((Join-Path $f.Output 'RunSummary.json')).Contains('synthetic-private-credential')) 'Private token error body persisted'
}

Invoke-Test 'Native OAuth honors throttling, refreshes once on 401, and never switches users across audiences' {
    $f = New-Fixture
    $f.NativeOptions = New-NativeFixtureOptions $f
    $original = $f.NativeOptions.AuthTokenRequest
    $attempts = @{ Count = 0 }
    $f.NativeOptions.AuthTokenRequest = {
        param($Request)
        $attempts.Count++
        if ($attempts.Count -eq 1) {
            return @{ StatusCode = 429; Headers = @{ 'Retry-After' = '2' }; Body = '' }
        }
        & $original $Request
    }.GetNewClosure()
    $f.Actions.Enqueue(@{ Kind = 'InventoryApps'; Status = 401; Headers = @{} })
    $s = Invoke-Fixture $f
    Assert-Equal $s.IncompleteSources 0 'Native throttle/401 did not recover'
    Assert-True ($f.Sleeps.Contains([double]2000)) 'OAuth server backoff was ignored'
    Assert-Equal @($f.AuthCalls | Where-Object Scope -eq 'https://api.powerplatform.com/.default').Count 2 'Native 401 caused a refresh storm'
    $g = New-Fixture
    $g.NativeOptions = New-NativeFixtureOptions $g
    $original = $g.NativeOptions.AuthTokenRequest
    $g.NativeOptions.AuthTokenRequest = {
        param($Request)
        $response = & $original $Request
        $form = & $module { param($Text) ConvertFrom-FormBody $Text } $Request.Body
        if ($form.scope -ne 'https://api.powerplatform.com/.default') {
            $body = $response.Body | ConvertFrom-Json
            $claims = & $module { param($Token) Read-TokenClaims $Token } $body.access_token
            $claims.oid = '66666666-6666-4666-8666-666666666666'
            $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $claims -Compress)))
            $payload = $payload.TrimEnd('=').Replace('+', '-').Replace('/', '_')
            $body.access_token = "e30.$payload.synthetic-not-a-credential"
            $response.Body = ConvertTo-Json -InputObject $body -Compress
        }
        return $response
    }.GetNewClosure()
    Assert-Equal (Invoke-Fixture $g).ExitCode 1 'A different user token was accepted for Dataverse'
}

Invoke-Test 'Native OAuth refuses server waits beyond its budget without shortening the delay' {
    $f = New-Fixture
    $f.Budget = 1
    $f.NativeOptions = New-NativeFixtureOptions $f
    $attempts = @{ Count = 0 }
    $f.NativeOptions.AuthTokenRequest = {
        param($Request)
        $attempts.Count++
        return @{ StatusCode = 429; Headers = @{ 'Retry-After' = '120' }; Body = '' }
    }.GetNewClosure()
    Assert-Throws { Invoke-Fixture $f } 'retry budget was exhausted'
    Assert-Equal $attempts.Count 1 'OAuth immediately retried a longer server-requested delay'
    Assert-Equal $f.Sleeps.Count 0 'OAuth shortened server backoff'
}

Invoke-Test 'PKCE uses the RFC S256 test vector and auth form parsing rejects duplicates' {
    $challenge = & $module { Get-AuthPkceChallenge 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk' }
    Assert-Equal $challenge 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM' 'PKCE SHA256 challenge'
    Assert-Throws { & $module { ConvertFrom-FormBody 'state=a&state=b' } } 'Duplicate'
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
    $f.Actions.Enqueue(@{ Kind = 'InventoryApps'; Throw = [System.Net.WebException]::new('synthetic') })
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
                $state = & $module { param($Path) Read-JsonFile $Path } $path
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
    $probeRoot = Join-Path $testDataRoot 'cross-process'
    $executable = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    & $executable -NoLogo -NoProfile -File $PSCommandPath -ProcessProbe Create -OutputDirectory $probeRoot
    Assert-Equal $LASTEXITCODE 0 'Cross-process initial checkpoint'
    & $executable -NoLogo -NoProfile -File $PSCommandPath -ProcessProbe Resume -OutputDirectory $probeRoot
    Assert-Equal $LASTEXITCODE 0 'Cross-process resume failed'
}

if ($OtherPowerShellPath) {
    Invoke-Test 'Inventory checkpoints resume in both directions between Windows PowerShell and PowerShell 7' {
        $current = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        foreach ($direction in @('CurrentToOther', 'OtherToCurrent')) {
            $probeRoot = Join-Path $testDataRoot $direction
            $createEngine = if ($direction -eq 'CurrentToOther') { $current } else { $OtherPowerShellPath }
            $resumeEngine = if ($direction -eq 'CurrentToOther') { $OtherPowerShellPath } else { $current }
            & $createEngine -NoLogo -NoProfile -File $PSCommandPath -ProcessProbe Create -OutputDirectory $probeRoot
            Assert-Equal $LASTEXITCODE 0 'Initial cross-engine checkpoint failed'
            & $resumeEngine -NoLogo -NoProfile -File $PSCommandPath -ProcessProbe Resume -OutputDirectory $probeRoot
            Assert-Equal $LASTEXITCODE 0 'Cross-engine resume changed hashes or lost app IDs'
        }
    }
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
        $f.NativeOptions = New-NativeFixtureOptions $f
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
            PowerShellVersion = $PSVersionTable.PSVersion.ToString(); PSEdition = $PSVersionTable.PSEdition
            AuthenticationMode = $s.AuthenticationMode
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
    PowerShellVersion = $PSVersionTable.PSVersion.ToString(); PSEdition = $PSVersionTable.PSEdition
    Passed = $results.Count - $failed; Failed = $failed
    Seconds = $timer.Elapsed.TotalSeconds; ScaleSkipped = [bool]$SkipScale
    LiveTenantTested = $false; Tests = $results.ToArray()
    TestDataDirectory = $testDataRoot
}
[IO.File]::WriteAllText((Join-Path $testRoot 'test-results.json'), (ConvertTo-Json -InputObject $evidence -Depth 10))
Write-Host "$($evidence.Passed) passed, $failed failed; $([Math]::Round($timer.Elapsed.TotalSeconds, 2)) seconds"
Write-Host "Evidence: $testRoot"
if (-not $KeepOutput -and $failed -eq 0) {
    [IO.Directory]::Delete($testDataRoot, $true)
    foreach ($path in [IO.Directory]::EnumerateDirectories($testRoot)) {
        [IO.Directory]::Delete($path, $true)
    }
}
if ($failed -gt 0) { exit 1 }
exit 0

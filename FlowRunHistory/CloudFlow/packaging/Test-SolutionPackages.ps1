#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$SolutionDirectory,
    [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')][string]$Version,
    [string]$PacPath = 'pac',
    [string]$ResultsPath,
    [switch]$SkipRoundTrip
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $PSBoundParameters.ContainsKey('SolutionDirectory')) { $SolutionDirectory = Join-Path $PSScriptRoot '..\Solutions' }
if ([string]::IsNullOrWhiteSpace($SolutionDirectory)) { throw 'SolutionDirectory cannot be empty.' }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$profiles = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'SolutionProfiles.json') | ConvertFrom-Json
if (-not $Version) { $Version = $profiles.Version }
$results = [Collections.Generic.List[object]]::new()
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('flow-history-package-tests-' + [guid]::NewGuid().ToString('N'))
if ([IO.Directory]::Exists($temporary)) { throw 'Private test directory already exists.' }
$null = [IO.Directory]::CreateDirectory($temporary)

function Assert {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Case {
    param([string]$Label, [scriptblock]$Body)
    try { & $Body; $results.Add(@{ Name = $Label; Passed = $true }); Write-Host "PASS $Label" }
    catch { $results.Add(@{ Name = $Label; Passed = $false; Error = $_.Exception.Message }); Write-Host "FAIL $Label : $($_.Exception.Message)"; Write-Host $_.ScriptStackTrace }
}

function Read-Zip {
    param([string]$Path)
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    $content = @{}
    try {
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            Assert (-not $content.ContainsKey($name)) 'Duplicate ZIP entry.'
            Assert ($name -notmatch '(^/|\\|(^|/)\.\.(/|$)|:)') 'Unsafe ZIP entry path.'
            $reader = [IO.StreamReader]::new($entry.Open())
            try { $content[$name] = $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
    }
    finally { $zip.Dispose() }
    return ,$content
}

function No-SecureData {
    param($Object)
    if ($Object -is [pscustomobject]) {
        foreach ($property in $Object.PSObject.Properties) {
            Assert ($property.Name -cne 'secureData') 'Explicit Secure Inputs/Outputs configuration remains in a packaged action or trigger.'
            No-SecureData $property.Value
        }
    }
    elseif ($Object -is [Collections.IEnumerable] -and $Object -isnot [string]) {
        foreach ($item in $Object) { No-SecureData $item }
    }
}

function Canonical-Json {
    param($Object)
    if ($null -eq $Object -or $Object -is [string] -or $Object -is [ValueType]) { return $Object }
    if ($Object -is [pscustomobject]) {
        $ordered = [ordered]@{}
        foreach ($property in @($Object.PSObject.Properties | Sort-Object Name)) {
            $ordered[$property.Name] = Canonical-Json $property.Value
        }
        return [pscustomobject]$ordered
    }
    return ,@($Object | ForEach-Object { Canonical-Json $_ })
}

function Equivalent-Zip {
    param($First, $Second)
    Assert (@(Compare-Object @($First.Keys | Sort-Object) @($Second.Keys | Sort-Object)).Count -eq 0) 'PAC round-trip changed the set of solution entries.'
    foreach ($name in $First.Keys) {
        if ($name.EndsWith('.json')) {
            $left = Canonical-Json (ConvertFrom-Json -InputObject $First[$name])
            $right = Canonical-Json (ConvertFrom-Json -InputObject $Second[$name])
            Assert ((ConvertTo-Json -InputObject $left -Depth 100 -Compress) -ceq
                (ConvertTo-Json -InputObject $right -Depth 100 -Compress)) "Round-trip JSON changed: $name"
        }
        elseif ($name.EndsWith('.xml')) {
            $left = [xml]$First[$name]; $right = [xml]$Second[$name]
            foreach ($document in @($left, $right)) {
                foreach ($roots in $document.SelectNodes('//RootComponents')) {
                    $ordered = @($roots.ChildNodes | Where-Object NodeType -eq ([Xml.XmlNodeType]::Element) |
                        Sort-Object { $_.GetAttribute('type') + '|' + $_.GetAttribute('schemaName') + '|' + $_.GetAttribute('id') })
                    foreach ($component in $ordered) { $null = $roots.AppendChild($component) }
                }
            }
            Assert ($left.OuterXml -ceq $right.OuterXml) "Round-trip XML changed: $name"
        }
        else { Assert ($First[$name] -ceq $Second[$name]) "Round-trip content changed: $name" }
    }
}

function Pac-Offline {
    param([string[]]$Arguments)
    & $PacPath @Arguments | ForEach-Object { Write-Verbose $_ }
    if ($LASTEXITCODE -ne 0) { throw "PAC offline operation failed with exit code $LASTEXITCODE." }
}

try {
    Case 'Public and GCC retain distinct stable portable workflow, reference and solution lineage' {
        Assert ($profiles.Public.WorkflowId -cne $profiles.GCC.WorkflowId) 'Variants share a workflow identity.'
        Assert ($profiles.Public.UniqueName -cne $profiles.GCC.UniqueName) 'Variants share a solution identity.'
        Assert ($profiles.Public.HttpReference -cne $profiles.GCC.HttpReference -and
            $profiles.Public.SharePointReference -cne $profiles.GCC.SharePointReference) 'Variants share cloud-bound logical references.'
        foreach ($name in @('Public', 'GCC')) {
            Assert ([guid]$profiles.$name.WorkflowId -ne [guid]::Empty) 'Portable workflow ID is empty.'
        }
    }
    foreach ($name in @('Public', 'GCC')) {
        $profile = $profiles.$name
        $file = 'FlowRunHistoryCollector_{0}_{1}_unmanaged.zip' -f $name, $Version.Replace('.', '_')
        $path = Join-Path $SolutionDirectory $file
        $content = Read-Zip $path
        $solution = [xml]$content['solution.xml']
        $customizations = [xml]$content['customizations.xml']
        $workflows = @($customizations.SelectNodes('/ImportExportXml/Workflows/Workflow'))
        $flowFiles = @($content.Keys | Where-Object { $_ -like 'Workflows/*.json' })
        Assert ($flowFiles.Count -eq 1) 'Must contain exactly one workflow JSON file.'
        $flow = ConvertFrom-Json -InputObject $content[$flowFiles[0]]
        $variables = @($content.Keys | Where-Object { $_ -like 'environmentvariabledefinitions/*/environmentvariabledefinition.xml' })

        Case "$name is a genuine unmanaged solution ZIP with exactly one stopped cloud flow" {
            Assert ([IO.FileInfo]::new($path).Length -gt 1000) 'Solution archive is empty or implausibly small.'
            Assert ($content.ContainsKey('solution.xml') -and $content.ContainsKey('customizations.xml') -and $content.ContainsKey('[Content_Types].xml')) 'Native solution entries missing.'
            Assert ($solution.ImportExportXml.SolutionManifest.Managed -ceq '0') 'Package is not unmanaged.'
            Assert ($solution.ImportExportXml.SolutionManifest.UniqueName -ceq $profile.UniqueName) 'Unexpected solution unique name.'
            Assert ($solution.ImportExportXml.SolutionManifest.Version -ceq $Version) 'Version mismatch.'
            Assert ($workflows.Count -eq 1 -and $workflows[0].WorkflowId.Trim('{}') -ceq $profile.WorkflowId) 'Workflow identity/count mismatch.'
            Assert ($workflows[0].StateCode -ceq '0' -and $workflows[0].StatusCode -ceq '1') 'Collector is not Off/Draft by default.'
            Assert ($workflows[0].Category -ceq '5' -and $workflows[0].Type -ceq '1') 'Genuine modern-flow metadata was not preserved.'
            Assert ($workflows[0].JsonFileName.TrimStart('/') -ceq $flowFiles[0]) 'Native workflow metadata points to a different file.'
            Assert ($flow.properties.definition.triggers.manual.type -ceq 'Request' -and
                $flow.properties.definition.triggers.manual.kind -ceq 'Button') 'Packaged collector is not manually runnable.'
        }
        Case "$name references two unbound Embedded import-mapped connections and no source binding" {
            $references = @($flow.properties.connectionReferences.PSObject.Properties)
            Assert ($references.Count -eq 2) 'Expected exactly two required connection references.'
            $xmlReferences = @($customizations.SelectNodes('//connectionreference'))
            Assert ($xmlReferences.Count -eq 2) 'Expected exactly two connection reference components.'
            foreach ($reference in $references) {
                Assert ($reference.Value.runtimeSource -ceq 'embedded') 'Caller/Invoker binding found.'
                Assert (@($reference.Value.connection.PSObject.Properties.Name).Count -eq 1 -and
                    $reference.Value.connection.connectionReferenceLogicalName) 'Actual connection identity or unsupported binding field remains.'
                $logicalName = $profile.HttpReference
                if ($reference.Name -ceq 'shared_sharepointonline') { $logicalName = $profile.SharePointReference }
                Assert ($reference.Value.connection.connectionReferenceLogicalName -ceq $logicalName) 'Flow and reference component logical names differ.'
                $component = @($xmlReferences | Where-Object connectionreferencelogicalname -CEQ $logicalName)
                Assert ($component.Count -eq 1 -and $component[0].connectorid -ceq ('/providers/Microsoft.PowerApps/apis/' + $reference.Name)) 'Import reference component missing or incorrect connector.'
            }
        }
        Case "$name has three supported environment-variable definitions and no source current values" {
            Assert ($variables.Count -eq 3) 'Expected exactly three configuration definitions.'
            $definitions = @{}
            foreach ($fileName in $variables) {
                $variable = ([xml]$content[$fileName]).environmentvariabledefinition
                $definitions[$variable.schemaname] = $variable
                Assert ($variable.type -ceq '100000000') 'Configuration must be ordinary Text.'
            }
            $parameters = @($flow.properties.definition.parameters.PSObject.Properties | Where-Object { $_.Name -notin @('$authentication', '$connections') })
            Assert ($parameters.Count -eq 3) 'Expected exactly three definition parameter bindings.'
            foreach ($parameter in $parameters) {
                $schema = $parameter.Value.metadata.schemaName
                Assert ($definitions.ContainsKey($schema) -and $parameter.Value.type -ceq 'String') 'Parameter metadata.schemaName is not bound to a packaged definition.'
                Assert ($schema.StartsWith("fhr_$name")) 'Configuration is not isolated by cloud profile.'
                if ($schema.EndsWith('ReportFolderPath')) {
                    Assert ($definitions[$schema].defaultvalue -ceq '/Shared Documents/FlowRunHistory') 'Portable report folder default changed.'
                }
                else {
                    Assert ($definitions[$schema].isrequired -ceq '1') 'Tenant/site must be required import configuration.'
                    Assert (-not $definitions[$schema].SelectSingleNode('defaultvalue') -and $parameter.Value.defaultValue -ceq '') 'Source tenant/site default remains.'
                }
            }
            Assert (@($content.Keys | Where-Object { $_ -match '(?i)environmentvariablevalue' }).Count -eq 0) 'Source current environment-variable values were shipped.'
            $definition = $flow.properties.definition
            Assert ($definition.actions.Compose_report_manifest.inputs.TenantId.StartsWith("@parameters('Target tenant ID (fhr_")) 'Manifest has a fixed target tenant.'
            Assert ($null -eq $definition.actions.PSObject.Properties['Write_JSON_report']) 'Expected the original conditional export structure, not a new unguarded write.'
            $allFlow = $content[$flowFiles[0]]
            Assert ($allFlow.Contains("@parameters('Report SharePoint site URL (fhr_$name" )) 'Report actions do not use the imported site variable.'
            Assert ($allFlow.Contains('Validate_solution_configuration')) 'Blank/invalid configuration does not fail explicitly.'
        }
        Case "$name contains no explicit secure-I/O flags while OAuth and safety guards remain" {
            No-SecureData $flow.properties.definition
            Assert ($flow.properties.definition.parameters.'$authentication'.type -ceq 'SecureObject') 'Required authentication parameter type was removed.'
            $text = $content[$flowFiles[0]]
            Assert ($text.Contains('Guard_authenticated_origin') -and $text.Contains('Guard_anonymous_content_origin')) 'Cloud/origin checks were removed.'
            Assert ($text.Contains('Payload_contains_sensitive_marker') -and $text.Contains('Withhold_credential_bearing_payload')) 'Report credential/link withholding was removed.'
            Assert ($text.Contains('No explicit Secure Inputs/Outputs')) 'Run-history visibility warning missing.'
        }
        Case "$name is portable, profile-correct and contains no captured identities, URLs or history" {
            $all = $content.Values -join "`n"
            foreach ($match in [regex]::Matches($all, '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b')) {
                Assert ($match.Value.ToLowerInvariant() -in @($profile.WorkflowId, '00000000-0000-0000-0000-000000000000')) 'Unexpected tenant/environment/workflow/user identity literal in public package.'
            }
            Assert ($all -notmatch '(?i)https://[^/"\s]+\.sharepoint\.(com|us)|\.crm\d*\.dynamics\.com|Bearer\s+[A-Za-z0-9]|https://[^\s"''<>]*[?&]sig=|shared-webcontents-[0-9a-f]|shared-sharepointonl-[0-9a-f]|REPLACE_WITH_|__SOLUTION_|__WORKFLOW_|__SCHEMA_|jakegwynndemo') 'A bound URL, connection, credential or template marker remains.'
            Assert ($flow.properties.definition.actions.Compose_report_manifest.inputs.Cloud -ceq $name) 'Manifest cloud incorrect.'
            $correct = 'https://api.flow.microsoft.com'; $wrong = 'https://gov.api.flow.microsoft.us'
            if ($name -eq 'GCC') { $correct = 'https://gov.api.flow.microsoft.us'; $wrong = 'https://api.flow.microsoft.com' }
            Assert ($content[$flowFiles[0]].Contains($correct) -and -not $content[$flowFiles[0]].Contains($wrong)) 'Workflow contains wrong-cloud API routes.'
            Assert ($solution.ImportExportXml.SolutionManifest.Publisher.UniqueName -ceq 'PowerPlatformSolutions') 'Source/demo publisher was retained.'
            Assert ($content.Count -eq 7) 'Unexpected helper, source record, report, settings or private file shipped inside the solution.'
        }
        Case "$name deployment settings contain only empty mappings and the portable folder default" {
            $settingsFile = Join-Path $SolutionDirectory ($file -replace '\.zip$', '.settings.example.json')
            $settings = Get-Content -Raw -LiteralPath $settingsFile | ConvertFrom-Json
            Assert (@($settings.ConnectionReferences).Count -eq 2 -and @($settings.EnvironmentVariables).Count -eq 3) 'PAC does not recognize expected mapping/configuration components.'
            foreach ($reference in $settings.ConnectionReferences) { Assert ([string]::IsNullOrEmpty($reference.ConnectionId)) 'Settings example binds a source connection.' }
            foreach ($variable in $settings.EnvironmentVariables) { Assert ([string]::IsNullOrEmpty($variable.Value)) 'Settings example contains a source current value.' }
        }
        if (-not $SkipRoundTrip) {
            Case "$name real PAC unpack-pack-unpack round trip preserves complete native solution content" {
                $unpacked = Join-Path $temporary ($name + '-unpacked')
                $repacked = Join-Path $temporary ($name + '-repacked.zip')
                $second = Join-Path $temporary ($name + '-second-unpack')
                Pac-Offline @('solution', 'unpack', '--zipfile', $path, '--folder', $unpacked, '--packagetype', 'Unmanaged', '--allowWrite', '--errorlevel', 'Warning')
                Pac-Offline @('solution', 'pack', '--folder', $unpacked, '--zipfile', $repacked, '--packagetype', 'Unmanaged', '--errorlevel', 'Warning')
                Pac-Offline @('solution', 'unpack', '--zipfile', $repacked, '--folder', $second, '--packagetype', 'Unmanaged', '--allowWrite', '--errorlevel', 'Warning')
                Equivalent-Zip $content (Read-Zip $repacked)
                Assert ([IO.Directory]::Exists((Join-Path $second 'Workflows'))) 'Round-tripped native workflow source missing.'
            }
        }
    }
}
finally {
    if ([IO.Directory]::Exists($temporary)) { [IO.Directory]::Delete($temporary, $true) }
}
$failed = @($results | Where-Object { -not $_.Passed })
$report = @{
    Engine = $PSVersionTable.PSVersion.ToString(); Version = $Version
    Passed = $results.Count - $failed.Count; Failed = $failed.Count; RoundTrip = (-not $SkipRoundTrip)
    Scope = 'Offline ZIP/PAC validation, not a tenant import, activation or service compatibility guarantee.'
    Tests = $results.ToArray()
}
if ($ResultsPath) { $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ResultsPath -Encoding UTF8 }
Write-Host "PowerShell $($report.Engine): $($report.Passed) package checks passed, $($report.Failed) failed; PAC round trip=$($report.RoundTrip)."
if ($failed.Count -gt 0) { exit 1 }

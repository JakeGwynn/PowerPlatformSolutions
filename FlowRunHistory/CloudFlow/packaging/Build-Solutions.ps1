#Requires -Version 5.1

<#
.SYNOPSIS
Builds genuine, stopped unmanaged Public/GCC solution ZIPs with installed PAC.

.DESCRIPTION
Offline maintainer build only. Uses sanitized templates derived from a genuine
Dataverse export plus the current collector generator. No tenant API, connection,
publisher, solution, authentication or deployment operation is invoked.
Released ZIPs are the end-user deployment artifacts; PowerShell/PAC is not needed
to import/run them through Power Platform Solutions.
#>
[CmdletBinding()]
param(
    [ValidateSet('Public', 'GCC')][string[]]$Cloud = @('Public', 'GCC'),
    [string]$OutputDirectory,
    [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')][string]$Version,
    [string]$PacPath = 'pac'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $PSBoundParameters.ContainsKey('OutputDirectory')) { $OutputDirectory = Join-Path $PSScriptRoot '..\Solutions' }
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { throw 'OutputDirectory cannot be empty.' }
$profiles = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'SolutionProfiles.json') | ConvertFrom-Json
if (-not $Version) { $Version = $profiles.Version }
$generator = Join-Path $PSScriptRoot '..\New-FlowHistoryCollector.ps1'
$destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
if (-not [IO.Directory]::Exists($destination)) { $null = [IO.Directory]::CreateDirectory($destination) }
$null = Get-Command $PacPath -ErrorAction Stop
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('flow-history-solutions-' + [guid]::NewGuid().ToString('N'))
if ([IO.Directory]::Exists($temporary)) { throw 'Private build directory already exists.' }
$null = [IO.Directory]::CreateDirectory($temporary)
$outputs = [Collections.Generic.List[object]]::new()

function Write-Utf8 {
    param([string]$Path, [string]$Content)
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Write-Xml {
    param([xml]$Document, [string]$Path)
    $settings = [Xml.XmlWriterSettings]::new()
    $settings.Encoding = [Text.UTF8Encoding]::new($false)
    $settings.Indent = $true
    $writer = [Xml.XmlWriter]::Create($Path, $settings)
    try { $Document.Save($writer) } finally { $writer.Dispose() }
}

function Read-Template {
    param([string]$Name)
    return [xml](Get-Content -Raw -LiteralPath (Join-Path (Join-Path $PSScriptRoot 'templates') $Name))
}

function Invoke-PacPackaging {
    param([string[]]$Arguments)
    & $PacPath @Arguments | ForEach-Object { Write-Verbose $_ }
    if ($LASTEXITCODE -ne 0) { throw "PAC offline packaging failed with exit code $LASTEXITCODE." }
}

try {
    foreach ($name in @($Cloud | Select-Object -Unique)) {
        $profile = $profiles.$name
        $fileName = 'FlowRunHistoryCollector_{0}_{1}_unmanaged.zip' -f $name, $Version.Replace('.', '_')
        $zipPath = Join-Path $destination $fileName
        $settingsPath = Join-Path $destination ($fileName -replace '\.zip$', '.settings.example.json')
        if ([IO.File]::Exists($zipPath) -or [IO.File]::Exists($settingsPath)) {
            throw "Build output already exists; preserve it and use a new version or output directory: $fileName"
        }
        $source = Join-Path $temporary $name
        $other = Join-Path $source 'Other'
        $workflows = Join-Path $source 'Workflows'
        $null = [IO.Directory]::CreateDirectory($other)
        $null = [IO.Directory]::CreateDirectory($workflows)
        $package = & $generator -Cloud $name -UseSolutionEnvironmentVariables
        $workflowFile = $profile.UniqueName + '-' + $profile.WorkflowId.ToUpperInvariant() + '.json'
        $workflowPath = Join-Path $workflows $workflowFile
        $id = '{' + $profile.WorkflowId + '}'

        $manifest = Read-Template 'Solution.xml'
        $m = $manifest.ImportExportXml.SolutionManifest
        $m.UniqueName = $profile.UniqueName
        $m.LocalizedNames.LocalizedName.SetAttribute('description', $profile.DisplayName)
        $m.Version = $Version
        $m.RootComponents.RootComponent.SetAttribute('id', $id)
        foreach ($setting in $package.deployment.environmentVariables) {
            $root = $manifest.CreateElement('RootComponent')
            $root.SetAttribute('type', '380')
            $root.SetAttribute('schemaName', $setting.SchemaName)
            $root.SetAttribute('behavior', '0')
            $null = $m.RootComponents.AppendChild($root)
        }
        Write-Xml $manifest (Join-Path $other 'Solution.xml')

        $customizations = Read-Template 'Customizations.xml'
        foreach ($reference in $customizations.ImportExportXml.connectionreferences.connectionreference) {
            $logicalName = $profile.HttpReference
            if ($reference.connectorid -like '*/shared_sharepointonline') { $logicalName = $profile.SharePointReference }
            $reference.SetAttribute('connectionreferencelogicalname', $logicalName)
        }
        Write-Xml $customizations (Join-Path $other 'Customizations.xml')

        $metadata = Read-Template 'Workflow.xml'
        $metadata.Workflow.SetAttribute('WorkflowId', $id)
        $metadata.Workflow.SetAttribute('Name', $profile.DisplayName)
        $metadata.Workflow.JsonFileName = '/Workflows/' + $workflowFile
        $metadata.Workflow.LocalizedNames.LocalizedName.SetAttribute('description', $profile.DisplayName)
        Write-Xml $metadata ($workflowPath + '.data.xml')

        $references = [ordered]@{}
        foreach ($connector in @('shared_webcontents', 'shared_sharepointonline')) {
            $logicalName = $profile.HttpReference
            if ($connector -eq 'shared_sharepointonline') { $logicalName = $profile.SharePointReference }
            $references[$connector] = @{
                runtimeSource = 'embedded'
                connection = @{ connectionReferenceLogicalName = $logicalName }
                api = @{ name = $connector }
            }
        }
        $flowExport = [ordered]@{
            properties = [ordered]@{
                connectionReferences = $references
                definition = $package.definition
                templateName = $null
            }
            schemaVersion = '1.0.0.0'
        }
        Write-Utf8 $workflowPath (ConvertTo-Json -InputObject $flowExport -Depth 100)

        foreach ($setting in $package.deployment.environmentVariables) {
            $folder = Join-Path (Join-Path $source 'environmentvariabledefinitions') $setting.SchemaName
            $null = [IO.Directory]::CreateDirectory($folder)
            $definition = Read-Template 'EnvironmentVariableDefinition.xml'
            $node = $definition.environmentvariabledefinition
            $node.SetAttribute('schemaname', $setting.SchemaName)
            $node.description.SetAttribute('default', $setting.Description)
            $node.description.label.SetAttribute('description', $setting.Description)
            $node.displayname.SetAttribute('default', $setting.DisplayName)
            $node.displayname.label.SetAttribute('description', $setting.DisplayName)
            $node.introducedversion = $Version
            $node.isrequired = $(if ($setting.Required) { '1' } else { '0' })
            if ($setting.DefaultValue) {
                $default = $definition.CreateElement('defaultvalue')
                $default.InnerText = $setting.DefaultValue
                $null = $node.AppendChild($default)
            }
            Write-Xml $definition (Join-Path $folder 'environmentvariabledefinition.xml')
        }

        $builtZip = Join-Path $temporary $fileName
        Invoke-PacPackaging @('solution', 'pack', '--folder', $source, '--zipfile', $builtZip,
            '--packagetype', 'Unmanaged', '--errorlevel', 'Warning')
        $generatedSettings = Join-Path $temporary ($name + '.settings.json')
        Invoke-PacPackaging @('solution', 'create-settings', '--solution-zip', $builtZip, '--settings-file', $generatedSettings)
        [IO.File]::Move($builtZip, $zipPath)
        [IO.File]::Move($generatedSettings, $settingsPath)
        $outputs.Add([pscustomobject]@{
            Cloud = $name; SolutionUniqueName = $profile.UniqueName; Version = $Version
            WorkflowId = $profile.WorkflowId; Managed = $false; DefaultState = 'Off'
            ZipPath = $zipPath; SettingsExamplePath = $settingsPath
            Sha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
        })
    }
}
finally {
    if ([IO.Directory]::Exists($temporary)) { [IO.Directory]::Delete($temporary, $true) }
}
$outputs.ToArray()

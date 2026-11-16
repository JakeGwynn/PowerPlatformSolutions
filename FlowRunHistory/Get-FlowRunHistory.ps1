#Requires -Version 5.1

<#
.SYNOPSIS
Reads Power Automate cloud-flow run history without changing any flows.

.DESCRIPTION
Returns a summary by default. All downloads available trigger/action inputs,
outputs, and loop repetitions. Errors adds error messages, including failed
actions and retries. CallingRecordId extracts only connector-aware Dataverse
row / SharePoint item identities; combine it with IdOnly for bare IDs.

Omitting FlowId discovers visible personal, shared, and solution cloud flows.
AsAdmin uses administrator discovery/history, not an ownership bypass.
Dates filter run START times, inclusively From and exclusively To, in UTC.
This uses the Power Automate service, not the Dataverse flowrun table.
CsvPath and JsonPath export the selected output mode without replacing pipeline
objects. Files are staged until retrieval finishes, and existing files are never
overwritten. Use All for full structured JSON and operation-level CSV rows.
See README.md for permissions, retention, and completeness limitations.

.PARAMETER TenantId
The target Microsoft Entra tenant GUID. Always explicit, including for guests.

.PARAMETER EnvironmentName
The environment resource name, such as Default-<tenant-guid>, not its display name.

.PARAMETER Cloud
Public (default) or GCC (Government Community Cloud / Moderate).
GCC uses public Entra authentication and government Flow endpoints, not GCC High.

.PARAMETER FlowId
One or more flow resource GUIDs. Omit to discover flows in the environment.

.PARAMETER RunId
One or more run names. Without FlowId, searches the discovered flows.

.PARAMETER AllFlows
Explicitly request discovery. Cannot be combined with FlowId.

.PARAMETER All
Download available trigger/action metadata and payloads, including repetitions.
Missing, secured, unsupported, or expired data is explicitly reported in Issues.

.PARAMETER Errors
Include run, trigger, action, repetition, and retry errors. Does not filter status.

.PARAMETER CallingRecordId
Return triggering record identity information, without action payloads.
Can be combined with Errors or All.

.PARAMETER IdOnly
With CallingRecordId alone, emit only verified record ID strings. Missing IDs
produce warnings, not guessed IDs. SharePoint uses the numeric list item ID.

.PARAMETER RecordSource
Limit record extraction to Dataverse and/or SharePoint.

.PARAMETER Status
Run statuses to include. Terminated also matches an exact run code of Terminated;
a Terminate action commonly finishes a run as Failed, Cancelled, or Succeeded.

.PARAMETER From
Inclusive run start time, ISO 8601 with Z or an explicit timezone offset.

.PARAMETER To
Exclusive run start time, ISO 8601 with Z or an explicit timezone offset.

.PARAMETER LastDays
Rolling UTC interval ending at invocation time. Cannot be combined with From/To.

.PARAMETER AsAdmin
Use admin flow discovery and run listing. Detail/payload access still requires
the service to authorize the user; no ownership changes are made.

.PARAMETER AccessToken
An externally acquired delegated Flow token (String, SecureString, or an object
with a Token property). No module is needed when this is supplied.

.PARAMETER UseExistingContext
Use an existing Az.Accounts USER context in this tenant and the selected cloud's
identity authority. Otherwise the script initiates Microsoft sign-in.

.PARAMETER DeviceCode
Use Microsoft's device-code sign-in instead of browser/broker sign-in.
Cannot be combined with AccessToken or UseExistingContext.

.PARAMETER SkipDependencyInstall
Do not install a missing/old Az.Accounts dependency. AccessToken never installs
dependencies regardless of this switch.

.PARAMETER DependencyRepository
Repository for automatic current-user Az.Accounts installation (default PSGallery).
PSGallery must have its official HTTPS URL. A custom repository must already
be registered and trusted. No repository trust or execution policy is changed.

.PARAMETER DataversePrimaryKey
Optional hashtable of table logical/entity-set names to actual primary key
attributes, for example @{ accounts = 'accountid'; widgets = 'new_widgetid' }.
No arbitrary GUID or lookup properties are guessed.

.PARAMETER DataverseUrl
Optional explicit organization HTTPS origin for primary-key metadata lookup.
No URL taken from a payload is used for authenticated metadata requests.

.PARAMETER DataverseAccessToken
Optional token for DataverseUrl, in the same tenant. Otherwise metadata uses
the explicitly selected Az user context, if one was selected for Flow.

.PARAMETER MaxRetries
Additional attempts for transient HTTP/network failures (default 4).

.PARAMETER RetryBudgetSeconds
Per-request retry budget (default 180). Retry-After is never shortened to fit.

.PARAMETER RequestTimeoutSeconds
Per-attempt timeout, including reading the body (default 120).

.PARAMETER MaxPayloadMB
Maximum buffered response size, including payloads (default 64 MiB).
Oversize/unreadable payloads are reported as unavailable, not truncated.

.PARAMETER CsvPath
New CSV file in an existing directory. Uses run/trigger/action/repetition rows
with compact JSON cells for nested data. With IdOnly, contains just RecordId.
No matches creates a header-only CSV. Pipeline objects are still returned.

.PARAMETER JsonPath
New UTF-8 JSON file in an existing directory. Always a structured JSON array,
including [] for no matches and ["id"] for IdOnly. May be combined with CsvPath.
No final export is published if retrieval terminates with an error.

.EXAMPLE
.\Get-FlowRunHistory.ps1 -TenantId '11111111-1111-4111-8111-111111111111' -EnvironmentName 'Default-11111111-1111-4111-8111-111111111111' -FlowId '22222222-2222-4222-8222-222222222222' -Status Failed -LastDays 7 -Errors

.EXAMPLE
$flows = '22222222-2222-4222-8222-222222222222', '33333333-3333-4333-8333-333333333333'
.\Get-FlowRunHistory.ps1 -TenantId $tenant -EnvironmentName $environment -FlowId $flows -Status Failed,Cancelled -LastDays 7 -CallingRecordId

.EXAMPLE
.\Get-FlowRunHistory.ps1 -TenantId $tenant -EnvironmentName $environment -AllFlows -AsAdmin -Status Failed -LastDays 14 -Errors

.EXAMPLE
.\Get-FlowRunHistory.ps1 -TenantId $tenant -EnvironmentName $environment -FlowId $flow -RunId $run -All | ConvertTo-Json -Depth 100

.EXAMPLE
.\Get-FlowRunHistory.ps1 -TenantId $tenant -EnvironmentName $environment -FlowId $flow -CallingRecordId -IdOnly -DataversePrimaryKey @{ accounts = 'accountid' }

.EXAMPLE
.\Get-FlowRunHistory.ps1 -TenantId $tenant -EnvironmentName $environment -FlowId $flows -Status Failed -LastDays 7 -All -CsvPath '.\failed-runs.csv' -JsonPath '.\failed-runs.json'

.EXAMPLE
.\Get-FlowRunHistory.ps1 -Cloud GCC -TenantId $tenant -EnvironmentName $environment -AllFlows -AsAdmin -Status Failed -LastDays 7 -Errors -CsvPath '.\gcc-errors.csv'

.NOTES
Windows PowerShell 5.1 / PowerShell 7. Public and GCC (Moderate) routing.
GCC routing is documentation/fixture-verified, not live-tested. GCC High, DoD,
and China are not supported. Only missing auth dependencies install automatically.
Signed content links and Authorization values are redacted from returned data.
Output can still contain sensitive business data; protect any exports.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EnvironmentName,
    [ValidateSet('Public', 'GCC')][string]$Cloud = 'Public',
    [Alias('FlowIds')][string[]]$FlowId = @(),
    [Alias('RunIds')][string[]]$RunId = @(),
    [switch]$AllFlows,
    [switch]$All,
    [switch]$Errors,
    [switch]$CallingRecordId,
    [switch]$IdOnly,
    [ValidateSet('Dataverse', 'SharePoint')][string[]]$RecordSource = @('Dataverse', 'SharePoint'),
    [ValidateSet('Succeeded', 'Failed', 'Cancelled', 'Running', 'Waiting', 'Suspended',
        'TimedOut', 'Aborted', 'Faulted', 'Skipped', 'Paused', 'Terminated')][string[]]$Status = @(),
    [Alias('StartTime', 'StartDate')][string]$From,
    [Alias('EndTime', 'EndDate')][string]$To,
    [ValidateRange(0.000001, 36500)][double]$LastDays,
    [switch]$AsAdmin,
    [object]$AccessToken,
    [switch]$UseExistingContext,
    [switch]$DeviceCode,
    [switch]$SkipDependencyInstall,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')][string]$DependencyRepository = 'PSGallery',
    [ValidateNotNull()][hashtable]$DataversePrimaryKey = @{},
    [uri]$DataverseUrl,
    [object]$DataverseAccessToken,
    [ValidateRange(0, 12)][int]$MaxRetries = 4,
    [ValidateRange(1, 86400)][int]$RetryBudgetSeconds = 180,
    [ValidateRange(1, 600)][int]$RequestTimeoutSeconds = 120,
    [ValidateRange(1, 1024)][int]$MaxPayloadMB = 64,
    [string]$CsvPath,
    [string]$JsonPath,
    [Parameter(DontShow)][uri]$TestApiBaseUri
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$supplied = @{} + $PSBoundParameters
$invocationTime = [DateTimeOffset]::UtcNow
$apiVersion = 'api-version=2016-11-01'
$cloudProfile = $null
$flowAudience = $null
$apiBase = $null
$minimumAzVersion = [version]'5.3.4'
$installAzVersion = '5.3.4'
$jsonParameters = @{}
if ($PSVersionTable.PSVersion.Major -ge 6) { $jsonParameters.NoEnumerate = $true }
if ($PSVersionTable.PSVersion -ge [version]'7.5') { $jsonParameters.DateKind = 'String' }
$azContext = $null
$metadataCache = @{}
$definitionCache = @{}
$http = $null
$handler = $null
$exportFiles = [System.Collections.Generic.List[object]]::new()
$exportResultCount = 0
$csvParameters = @{ Delimiter = ',' }
if ($PSVersionTable.PSVersion.Major -lt 6) { $csvParameters.NoTypeInformation = $true }
$csvColumns = @(
    'RowType', 'TenantId', 'Cloud', 'EnvironmentName', 'FlowId', 'FlowDisplayName', 'RunId', 'RunStatus',
    'RunStartTimeUtc', 'RunEndTimeUtc', 'RunDurationSeconds', 'OperationName', 'DefinitionPath',
    'RepetitionName', 'OperationId', 'Status', 'Code', 'StartTimeUtc', 'EndTimeUtc', 'DurationSeconds',
    'ClientTrackingId', 'TrackingId', 'ActionTrackingId', 'ClientRequestId', 'ServiceRequestId',
    'RepetitionIndexesJson', 'InputsAvailability', 'OutputsAvailability', 'InputsReason', 'OutputsReason',
    'InputsJson', 'OutputsJson', 'RepetitionsAvailability', 'ScopeRepetitionsAvailability',
    'ErrorCode', 'ErrorMessage', 'ErrorsJson', 'DetailCoverage', 'IssuesJson',
    'RecordSource', 'RecordId', 'RecordAvailability', 'Table', 'PrimaryKey', 'SiteUrl', 'ListId',
    'ItemId', 'UniqueId', 'RecordEvidence', 'ConnectorEvidence', 'TriggerOperation', 'RecordReason',
    'CallingRecordJson', 'RunCorrelationJson', 'CorrelationJson', 'RetryHistoryJson', 'MetadataJson',
    'DefinitionEvidence'
)

function Get-Field {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return ,$Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return ,$property.Value }
    return $null
}

function Test-Field {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Name) }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Get-Entries {
    param($Object)
    if ($null -eq $Object) { return }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) { [pscustomobject]@{ Name = [string]$key; Value = $Object[$key] } }
    }
    else {
        foreach ($property in $Object.PSObject.Properties) {
            [pscustomobject]@{ Name = $property.Name; Value = $property.Value }
        }
    }
}

function Get-CloudProfile {
    param([ValidateSet('Public', 'GCC')][string]$Name)
    if ($Name -eq 'GCC') {
        return [pscustomobject]@{
            Name = 'GCC'; AzEnvironment = 'AzureCloud'; Authority = 'https://login.microsoftonline.com'
            ApiBase = 'https://gov.api.flow.microsoft.us'
            Audience = 'https://gov.service.flow.microsoft.us/'
            Audiences = @('https://gov.service.flow.microsoft.us/')
            DataversePattern = '^[a-z0-9][a-z0-9-]*\.crm9\.dynamics\.com$'
            ContentSuffixes = @('logic.azure.us', 'api.gov.powerplatform.microsoft.us',
                'gov.api.flow.microsoft.us', 'blob.core.usgovcloudapi.net')
        }
    }
    return [pscustomobject]@{
        Name = 'Public'; AzEnvironment = 'AzureCloud'; Authority = 'https://login.microsoftonline.com'
        ApiBase = 'https://api.flow.microsoft.com'
        Audience = 'https://service.flow.microsoft.com/'
        Audiences = @('https://service.flow.microsoft.com/', 'https://api.flow.microsoft.com/')
        DataversePattern = '^[a-z0-9][a-z0-9-]*\.crm(?:[0-8]|[1-9][0-9]+)?\.dynamics\.com$'
        ContentSuffixes = @('logic.azure.com', 'api.powerplatform.com', 'flow.microsoft.com', 'blob.core.windows.net')
    }
}

function ConvertFrom-ServiceJson {
    param([string]$Content)
    $decoded = ConvertFrom-Json -InputObject $Content @jsonParameters -ErrorAction Stop
    return ,$decoded
}

function Protect-Text {
    param([string]$Text)
    $clean = [regex]::Replace($Text, '(?i)\bBearer\s+[A-Za-z0-9._~+/-]+=*', 'Bearer [REDACTED]')
    return [regex]::Replace($clean, '(?i)https?://[^\s''"<>]+', {
        param($match)
        if ($match.Value -match '(?i)[?&](sig|signature|token|access_token|code|key|sv|sp|se)=') {
            return '[REDACTED SIGNED URL]'
        }
        return $match.Value
    })
}

function Protect-Data {
    param($Value, [int]$Depth = 0)
    if ($Depth -gt 80) { throw 'Response nesting exceeds the safe output depth; data was not truncated.' }
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return Protect-Text $Value }
    if ($Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [System.Collections.IDictionary]) {
        $items = @(
            foreach ($item in $Value) { Protect-Data $item ($Depth + 1) }
        )
        return ,$items
    }
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject]) {
        $result = [ordered]@{}
        foreach ($entry in @(Get-Entries $Value)) {
            if ($entry.Name -in @('inputsLink', 'outputsLink', 'nextLink', '@odata.nextLink')) {
                $result[$entry.Name] = '[REDACTED CONTENT/PAGING LINK]'
            }
            elseif ($entry.Name -match '^(Authorization|Proxy-Authorization)$') {
                $result[$entry.Name] = '[REDACTED]'
            }
            else { $result[$entry.Name] = Protect-Data $entry.Value ($Depth + 1) }
        }
        return [pscustomobject]$result
    }
    return Protect-Text ([string]$Value)
}

function ConvertTo-UtcDate {
    param($Value, [string]$Label)
    if ($Value -is [DateTimeOffset]) { return $Value.ToUniversalTime() }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { throw "$Label has no timezone." }
        return [DateTimeOffset]::new($Value.ToUniversalTime())
    }
    if ($Value -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})$') {
        throw "$Label must be ISO 8601 with seconds and Z or an explicit timezone offset."
    }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        throw "$Label is not a valid date."
    }
    return $parsed.ToUniversalTime()
}

function ConvertTo-PlainToken {
    param($Value)
    if (Test-Field $Value 'Token') { $Value = Get-Field $Value 'Token' }
    if ($Value -is [securestring]) {
        return ([pscredential]::new('token', $Value)).GetNetworkCredential().Password
    }
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
        throw 'Supply a nonempty token String, SecureString, or object with a Token property.'
    }
    return $Value
}

function Assert-Token {
    param([string]$Token, [string[]]$Audiences)
    try {
        $segments = $Token.Split('.')
        if ($segments.Count -ne 3) { throw 'JWT required' }
        $encoded = $segments[1].Replace('-', '+').Replace('_', '/')
        $encoded = $encoded.PadRight($encoded.Length + ((4 - $encoded.Length % 4) % 4), '=')
        $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json
    }
    catch { throw 'The supplied access token is not a readable JWT; no request was sent.' }
    if ([string](Get-Field $claims 'tid') -ne $TenantId.ToString()) {
        throw 'Token tenant does not match TenantId. Sign in to the target tenant explicitly.'
    }
    $issuer = [string](Get-Field $claims 'iss')
    $validIssuers = @(
        "https://sts.windows.net/$($TenantId.ToString())/",
        "$($cloudProfile.Authority)/$($TenantId.ToString())/v2.0"
    )
    if ($issuer -notin $validIssuers) {
        throw 'Token issuer does not match the selected cloud identity authority and tenant. No cross-cloud fallback is used.'
    }
    $audience = ([string](Get-Field $claims 'aud')).TrimEnd('/')
    $expected = @($Audiences | ForEach-Object { $_.TrimEnd('/') })
    if ($audience -notin $expected) {
        throw 'Token audience is incorrect for this service. Do not use a Graph, ARM, or Dataverse token for Flow.'
    }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $expiry = 0L
    if (-not [long]::TryParse([string](Get-Field $claims 'exp'), [ref]$expiry) -or $expiry -le $now) {
        throw 'Access token has expired or has no expiry. Acquire a fresh delegated token.'
    }
    $notBefore = 0L
    if ([long]::TryParse([string](Get-Field $claims 'nbf'), [ref]$notBefore) -and $notBefore -gt $now + 60) {
        throw 'Access token is not valid yet. Check the system clock.'
    }
    if ((Get-Field $claims 'idtyp') -eq 'app' -or
        [string]::IsNullOrWhiteSpace([string](Get-Field $claims 'scp'))) {
        throw 'These run-history endpoints require a delegated user token; app-only authentication is not supported by this script.'
    }
}

function Install-AzAccounts {
    $originalProtocol = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = $originalProtocol -bor [Net.SecurityProtocolType]::Tls12
        Write-Information "Installing Az.Accounts $installAzVersion for CurrentUser from $DependencyRepository." -InformationAction Continue
        if (-not (Get-Command Install-Module -ErrorAction SilentlyContinue) -and
            (Get-Command Install-PSResource -ErrorAction SilentlyContinue)) {
            $repositories = @(Get-PSResourceRepository -ErrorAction Stop | Where-Object Name -eq $DependencyRepository)
            if ($repositories.Count -eq 0 -and $DependencyRepository -eq 'PSGallery') {
                Register-PSResourceRepository -PSGallery -ErrorAction Stop
                $repositories = @(Get-PSResourceRepository -ErrorAction Stop | Where-Object Name -eq 'PSGallery')
            }
            if ($repositories.Count -ne 1) { throw 'The dependency repository is not registered uniquely.' }
            $repository = $repositories[0]
            $source = [uri]$repository.Uri
            if ($DependencyRepository -eq 'PSGallery') {
                if ($source.AbsoluteUri.TrimEnd('/') -ne 'https://www.powershellgallery.com/api/v2') {
                    throw 'PSGallery is not registered with its official source URL; it was not modified or trusted.'
                }
            }
            elseif (-not $repository.Trusted) { throw 'The selected custom dependency repository must already be trusted.' }
            if ($source.Scheme -ne 'https' -or $source.UserInfo -or $source.Query -or $source.Fragment) {
                throw 'Dependency repositories must use an HTTPS source without embedded credentials or query parameters.'
            }
            Install-PSResource -Name Az.Accounts -Version $installAzVersion -Repository $DependencyRepository `
                -Scope CurrentUser -TrustRepository -AcceptLicense -Quiet -ErrorAction Stop
        }
        else {
            if (-not (Get-Command Install-Module -ErrorAction SilentlyContinue)) {
                throw 'Neither PowerShellGet nor PSResourceGet is installed. Preinstall Az.Accounts or use AccessToken.'
            }
            $repositories = @(Get-PSRepository -ErrorAction Stop | Where-Object Name -eq $DependencyRepository)
            if ($repositories.Count -eq 0 -and $DependencyRepository -eq 'PSGallery') {
                Register-PSRepository -Default -ErrorAction Stop
                $repositories = @(Get-PSRepository -ErrorAction Stop | Where-Object Name -eq 'PSGallery')
            }
            if ($repositories.Count -ne 1) { throw 'The dependency repository is not registered uniquely.' }
            $repository = $repositories[0]
            $source = [uri]$repository.SourceLocation
            if ($DependencyRepository -eq 'PSGallery') {
                if ($source.AbsoluteUri.TrimEnd('/') -ne 'https://www.powershellgallery.com/api/v2') {
                    throw 'PSGallery is not registered with its official source URL; it was not modified or trusted.'
                }
            }
            elseif ($repository.InstallationPolicy -ne 'Trusted') {
                throw 'The selected custom dependency repository must already be trusted.'
            }
            if ($source.Scheme -ne 'https' -or $source.UserInfo -or $source.Query -or $source.Fragment) {
                throw 'Dependency repositories must use an HTTPS source without embedded credentials or query parameters.'
            }
            $providers = @(Get-PackageProvider -ListAvailable -ErrorAction Stop |
                Where-Object { $_.Name -eq 'NuGet' -and $_.Version -ge [version]'2.8.5.201' })
            if ($providers.Count -eq 0) {
                $null = Install-PackageProvider -Name NuGet -MinimumVersion '2.8.5.201' -Scope CurrentUser -Force -ErrorAction Stop
            }
            $install = @{
                Name = 'Az.Accounts'; RequiredVersion = $installAzVersion
                Repository = $DependencyRepository; Scope = 'CurrentUser'; Force = $true; ErrorAction = 'Stop'
            }
            if ((Get-Command Install-Module).Parameters.ContainsKey('AcceptLicense')) { $install.AcceptLicense = $true }
            Install-Module @install
        }
    }
    catch {
        throw [InvalidOperationException]::new(
            "Automatic Az.Accounts installation failed. Check repository/proxy access and organization policy, or preinstall the module and use -SkipDependencyInstall / -AccessToken. $(Protect-Text $_.Exception.Message)")
    }
    finally { [Net.ServicePointManager]::SecurityProtocol = $originalProtocol }
}

function Initialize-AzModule {
    $loaded = @(Get-Module -Name Az.Accounts)
    if ($loaded.Count -gt 0 -and @($loaded | Where-Object Version -lt $minimumAzVersion).Count -gt 0) {
        throw "An older Az.Accounts is already loaded. Start a fresh PowerShell process with Az.Accounts $minimumAzVersion or later; loaded assemblies will not be replaced."
    }
    $available = @(Get-Module -ListAvailable -Name Az.Accounts |
        Where-Object { $_.Version -ge $minimumAzVersion -and
            ($null -eq $_.PowerShellVersion -or $_.PowerShellVersion -le $PSVersionTable.PSVersion) } |
        Sort-Object Version -Descending)
    if ($available.Count -eq 0) {
        if ($SkipDependencyInstall) {
            throw "Az.Accounts $minimumAzVersion or later is missing for this engine. Remove -SkipDependencyInstall to install it, preinstall it, or supply -AccessToken."
        }
        Install-AzAccounts
        $available = @(Get-Module -ListAvailable -Name Az.Accounts |
            Where-Object { $_.Version -ge $minimumAzVersion -and
                ($null -eq $_.PowerShellVersion -or $_.PowerShellVersion -le $PSVersionTable.PSVersion) } |
            Sort-Object Version -Descending)
    }
    if ($available.Count -eq 0) { throw 'Az.Accounts installation did not produce a compatible module in this engine module path.' }
    try { Import-Module -Name $available[0].Path -ErrorAction Stop }
    catch {
        throw [InvalidOperationException]::new(
            "Az.Accounts could not be imported. Windows PowerShell requires .NET Framework 4.7.2 or later; organization execution/signature policy still applies. $(Protect-Text $_.Exception.Message)")
    }
}

function Initialize-AzContext {
    Initialize-AzModule
    if ($UseExistingContext) {
        $script:azContext = Az.Accounts\Get-AzContext -ErrorAction Stop
    }
    else {
        $loginParameters = @{
            Tenant = $TenantId.ToString(); Environment = $cloudProfile.AzEnvironment
            Scope = 'Process'; SkipContextPopulation = $true; ErrorAction = 'Stop'
        }
        if ($DeviceCode) { $loginParameters.UseDeviceAuthentication = $true }
        $login = Az.Accounts\Connect-AzAccount @loginParameters
        $script:azContext = $login.Context
    }
    if ($null -eq $script:azContext -or
        [string]$script:azContext.Tenant.Id -ne $TenantId.ToString() -or
        [string]$script:azContext.Account.Type -ne 'User' -or
        [string]$script:azContext.Environment.Name -ne $cloudProfile.AzEnvironment -or
        ([string](Get-Field $script:azContext.Environment 'ActiveDirectoryAuthority')).TrimEnd('/') -ne $cloudProfile.Authority) {
        throw 'Az context must be a User in TenantId and the selected cloud identity authority. No other tenant/account context will be used.'
    }
}

function Get-ServiceToken {
    param([ValidateSet('Flow', 'Dataverse')][string]$Service)
    if ($Service -eq 'Flow') {
        $value = $AccessToken
        $audiences = $cloudProfile.Audiences
        $resource = $flowAudience
    }
    else {
        $value = $DataverseAccessToken
        $audiences = @($DataverseUrl.GetLeftPart([UriPartial]::Authority) + '/')
        $resource = $audiences[0]
    }
    if ($null -eq $value) {
        if ($null -eq $script:azContext) { throw 'Dataverse metadata requires DataverseAccessToken or the selected Az user context.' }
        $value = Az.Accounts\Get-AzAccessToken -ResourceUrl $resource -TenantId $TenantId.ToString() -DefaultProfile $script:azContext -ErrorAction Stop
    }
    $plain = ConvertTo-PlainToken $value
    Assert-Token $plain $audiences
    return $plain
}

function New-HttpFailure {
    param([string]$Message, [int]$StatusCode = 0)
    $exception = [InvalidOperationException]::new($Message)
    $exception.Data['StatusCode'] = $StatusCode
    return $exception
}

function Get-FailureStatus {
    param($ErrorRecord)
    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        if ($exception.Data.Contains('StatusCode')) { return [int]$exception.Data['StatusCode'] }
        $exception = $exception.InnerException
    }
    return 0
}

function Assert-ContentUri {
    param([uri]$Uri)
    if (-not $Uri.IsAbsoluteUri -or $Uri.UserInfo -or $Uri.Fragment) {
        throw 'Content link is not an absolute, credential-free URI.'
    }
    if ($null -ne $TestApiBaseUri -and $Uri.IsLoopback -and
        $Uri.Scheme -eq $apiBase.Scheme -and $Uri.Authority -eq $apiBase.Authority) { return }
    if ($Uri.Scheme -ne 'https' -or $Uri.Port -ne 443 -or $Uri.IsLoopback) {
        throw 'Content link must use HTTPS on a supported Microsoft content host.'
    }
    $userContentSuffix = '.environment.api.powerplatformusercontent.com'
    if ($cloudProfile.Name -eq 'Public' -and $Uri.DnsSafeHost.EndsWith($userContentSuffix, [StringComparison]::OrdinalIgnoreCase)) {
        $prefix = $Uri.DnsSafeHost.Substring(0, $Uri.DnsSafeHost.Length - $userContentSuffix.Length)
        if ($prefix -match '^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$' -and
            $Uri.AbsolutePath.StartsWith('/storage/powerautomate/automations/', [StringComparison]::Ordinal)) { return }
        throw 'Power Platform user-content link is outside the supported automation storage namespace.'
    }
    foreach ($suffix in $cloudProfile.ContentSuffixes) {
        if ($Uri.DnsSafeHost -eq $suffix -or $Uri.DnsSafeHost.EndsWith('.' + $suffix, [StringComparison]::OrdinalIgnoreCase)) { return }
    }
    throw 'Content link host is not supported in the selected cloud. It was blocked; no bearer token or request was sent.'
}

function Invoke-ReadRequest {
    param([uri]$Uri, [ValidateSet('Flow', 'Dataverse', 'Content')][string]$Service, [string]$Label)
    if ($Service -eq 'Flow' -and
        ($Uri.Scheme -ne $apiBase.Scheme -or $Uri.Authority -ne $apiBase.Authority)) {
        throw 'Blocked a Flow request outside the explicitly selected API origin.'
    }
    if ($Service -eq 'Dataverse' -and
        $Uri.GetLeftPart([UriPartial]::Authority) -ne $DataverseUrl.GetLeftPart([UriPartial]::Authority)) {
        throw 'Blocked a metadata request outside DataverseUrl.'
    }
    if ($Service -eq 'Content') { Assert-ContentUri $Uri }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    for ($attempt = 0; $attempt -le $MaxRetries; $attempt++) {
        $remaining = $RetryBudgetSeconds - $watch.Elapsed.TotalSeconds
        if ($remaining -le 0) { throw (New-HttpFailure "$Label exceeded its retry budget.") }
        $requestUri = $Uri
        if ($Service -eq 'Dataverse' -and $null -ne $TestApiBaseUri) {
            $requestUri = [uri]::new($apiBase, $Uri.PathAndQuery)
        }
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $requestUri)
        $response = $null
        $cancellation = [Threading.CancellationTokenSource]::new()
        $cancellation.CancelAfter([TimeSpan]::FromSeconds([Math]::Min($RequestTimeoutSeconds, $remaining)))
        $statusCode = 0
        $retryAfter = $null
        $readFailed = $false
        try {
            $request.Headers.Accept.ParseAdd('application/json')
            if ($Service -ne 'Content') {
                $token = Get-ServiceToken $Service
                $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
                $token = $null
            }
            try {
                $response = $http.SendAsync($request, $cancellation.Token).GetAwaiter().GetResult()
                $statusCode = [int]$response.StatusCode
                $mediaType = ''
                if ($null -ne $response.Content.Headers.ContentType) {
                    $mediaType = $response.Content.Headers.ContentType.MediaType
                }
                $binary = $Service -eq 'Content' -and $mediaType -and
                    $mediaType -notmatch '^(text/|application/(?:json|[^;]+\+json|xml|[^;]+\+xml|javascript|x-www-form-urlencoded)$)'
                if ($binary) {
                    $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
                    $content = [Convert]::ToBase64String($bytes)
                }
                else { $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() }
            }
            catch {
                $readFailed = $true
                if ($null -ne $response) { $statusCode = [int]$response.StatusCode }
                if ($attempt -ge $MaxRetries) {
                    throw (New-HttpFailure "$Label could not be read (connection, timeout, or response-size limit); no response body or URL is logged." $statusCode)
                }
                $content = $null
            }
            if ($statusCode -ge 200 -and $statusCode -lt 300 -and $null -ne $content) {
                return [pscustomobject]@{ Content = $content; MediaType = $mediaType; IsBinary = [bool]$binary }
            }
            $transient = $readFailed -or $statusCode -eq 0 -or $statusCode -in @(408, 429, 500, 502, 503, 504)
            if (-not $transient -or $attempt -ge $MaxRetries) {
                $hint = ''
                if ($statusCode -eq 401) { $hint = ' Acquire a fresh correct-audience token in TenantId.' }
                if ($statusCode -eq 403) { $hint = ' The user lacks permission/consent for this operation; admin inventory does not grant payload access.' }
                if ($statusCode -in @(301, 302, 303, 307, 308)) { $hint = ' Redirects are blocked to prevent credential/link disclosure.' }
                throw (New-HttpFailure "$Label failed (HTTP $statusCode).$hint" $statusCode)
            }
            if ($null -ne $response -and $null -ne $response.Headers.RetryAfter) {
                if ($null -ne $response.Headers.RetryAfter.Delta) {
                    $retryAfter = $response.Headers.RetryAfter.Delta.TotalSeconds
                }
                elseif ($null -ne $response.Headers.RetryAfter.Date) {
                    $retryAfter = [Math]::Max(0, ($response.Headers.RetryAfter.Date - [DateTimeOffset]::UtcNow).TotalSeconds)
                }
            }
        }
        finally {
            if ($null -ne $response) { $response.Dispose() }
            $cancellation.Dispose()
            $request.Dispose()
        }
        $delay = [Math]::Min(30, [Math]::Pow(2, $attempt))
        if ($null -ne $retryAfter) { $delay = [Math]::Max(0, [double]$retryAfter) }
        if ($watch.Elapsed.TotalSeconds + $delay -gt $RetryBudgetSeconds) {
            throw (New-HttpFailure "$Label exceeded its retry budget; Retry-After was not shortened." $statusCode)
        }
        Write-Verbose "$Label transient failure (HTTP $statusCode); retry $($attempt + 1) of $MaxRetries in $delay seconds."
        if ($delay -gt 0) { Start-Sleep -Milliseconds ([int][Math]::Ceiling($delay * 1000)) }
    }
}

function Get-ServiceJson {
    param([uri]$Uri, [string]$Label, [string]$Service = 'Flow')
    $response = Invoke-ReadRequest $Uri $Service $Label
    try { $parsed = ConvertFrom-ServiceJson $response.Content }
    catch { throw (New-HttpFailure "$Label returned invalid JSON; no response body is logged.") }
    if ($null -eq $parsed) { throw (New-HttpFailure "$Label returned an empty JSON response.") }
    if ($parsed -is [array] -or $parsed -is [ValueType] -or $parsed -is [string]) {
        throw (New-HttpFailure "$Label did not return a JSON object; results are incomplete.")
    }
    return ,$parsed
}

function Get-Collection {
    param([uri]$Uri, [string]$Label, [string]$Service = 'Flow')
    $initial = $Uri
    $visited = @{}
    while ($null -ne $Uri) {
        if ($visited.ContainsKey($Uri.AbsoluteUri)) { throw "$Label repeated a paging link; collection is incomplete." }
        if ($Uri.Scheme -ne $initial.Scheme -or $Uri.Authority -ne $initial.Authority -or
            $Uri.AbsolutePath -ne $initial.AbsolutePath -or $Uri.UserInfo -or $Uri.Fragment) {
            throw "$Label supplied a paging link outside its collection; request blocked."
        }
        $visited[$Uri.AbsoluteUri] = $true
        $page = Get-ServiceJson $Uri $Label $Service
        $values = Get-Field $page 'value'
        if (-not (Test-Field $page 'value') -or
            ($values -isnot [array] -and $values -isnot [System.Collections.IList])) {
            throw "$Label did not return a value array collection; results are incomplete."
        }
        foreach ($item in $values) { $item }
        $next = [string](Get-Field $page 'nextLink')
        if (-not $next) { $next = [string](Get-Field $page '@odata.nextLink') }
        $Uri = $null
        if ($next) {
            $candidate = [uri]::new($initial, $next)
            $Uri = $candidate
        }
    }
}

function Get-Payload {
    param($Properties, [ValidateSet('inputs', 'outputs')][string]$Side)
    $secure = Get-Field (Get-Field $Properties 'secureData') 'properties'
    if ($Side -in @($secure) -or (Get-Field $Properties ('is' + $Side + 'Secure')) -eq $true) {
        return [pscustomobject]@{ Availability = 'Secured'; Reason = 'Secure data is not exposed by the service.'; Content = $null }
    }
    if (Test-Field $Properties $Side) {
        return [pscustomobject]@{ Availability = 'Available'; Reason = 'Inline'; Content = (Get-Field $Properties $Side) }
    }
    $link = Get-Field (Get-Field $Properties ($Side + 'Link')) 'uri'
    if (-not $link) {
        return [pscustomobject]@{
            Availability = 'NotReturned'
            Reason = 'No payload/link was returned: possibly secured, skipped, pending, expired, or not applicable.'
            Content = $null
        }
    }
    try {
        $response = Invoke-ReadRequest ([uri]$link) 'Content' "$Side payload"
        if ($response.IsBinary) {
            return [pscustomobject]@{
                Availability = 'Available'; Reason = 'Binary content represented losslessly as base64'
                Content = [pscustomobject]@{ '$content-type' = $response.MediaType; '$content' = $response.Content }
            }
        }
        if ([string]::IsNullOrWhiteSpace($response.Content)) {
            if ($response.MediaType -match '(?i)(/json|\+json)') {
                return [pscustomobject]@{ Availability = 'Unreadable'; Reason = 'The content endpoint returned empty JSON.'; Content = $null }
            }
            return [pscustomobject]@{ Availability = 'Available'; Reason = 'Empty text content'; Content = $response.Content }
        }
        try { $data = ConvertFrom-ServiceJson $response.Content }
        catch {
            if ($response.MediaType -match '(?i)(/json|\+json)') {
                return [pscustomobject]@{ Availability = 'Unreadable'; Reason = 'The content endpoint returned invalid JSON.'; Content = $null }
            }
            $data = $response.Content
        }
        return [pscustomobject]@{ Availability = 'Available'; Reason = 'Downloaded anonymously'; Content = $data }
    }
    catch {
        $code = Get-FailureStatus $_
        $availability = 'Unavailable'
        if ($code -in @(401, 403)) { $availability = 'DeniedOrExpired' }
        if ($code -in @(404, 410)) { $availability = 'DeletedOrExpired' }
        return [pscustomobject]@{ Availability = $availability; Reason = (Protect-Text $_.Exception.Message); Content = $null }
    }
}

function Add-Issue {
    param($List, [string]$Component, [string]$State, [string]$Message)
    $List.Add([pscustomobject]@{ Component = $Component; State = $State; Message = (Protect-Text $Message) })
}

function Add-PayloadIssue {
    param($Issues, [string]$Component, $Payload)
    if ($Payload.Availability -ne 'Available') {
        Add-Issue $Issues $Component $Payload.Availability $Payload.Reason
    }
}

function Get-FlowDefinition {
    param([string]$Id)
    if ($definitionCache.ContainsKey($Id)) { return $definitionCache[$Id] }
    $uri = "$flowRoot/flows/$Id`?$apiVersion"
    try {
        $flow = Get-ServiceJson $uri 'Flow definition'
        $result = [pscustomobject]@{ Availability = 'Available'; Flow = $flow; Reason = 'Current definition, not necessarily the historical run version.' }
    }
    catch {
        if ((Get-FailureStatus $_) -eq 401) { throw }
        $result = [pscustomobject]@{ Availability = 'Unavailable'; Flow = $null; Reason = $_.Exception.Message }
    }
    $definitionCache[$Id] = $result
    return $result
}

function Get-ActionDefinitions {
    param($Container, $Index, [string]$ParentPath = '')
    foreach ($entry in @(Get-Entries (Get-Field $Container 'actions'))) {
        $name = $entry.Name
        $definition = $entry.Value
        $path = $name
        if ($ParentPath) { $path = "$ParentPath/$name" }
        $Index[$name] = [pscustomobject]@{ Path = $path }
        Get-ActionDefinitions $definition $Index $path
        Get-ActionDefinitions (Get-Field $definition 'else') $Index "$path/else"
        Get-ActionDefinitions (Get-Field $definition 'default') $Index "$path/default"
        foreach ($case in @(Get-Entries (Get-Field $definition 'cases'))) {
            Get-ActionDefinitions $case.Value $Index "$path/$($case.Name)"
        }
    }
}

function Get-OperationProperties {
    param($Operation)
    if (Test-Field $Operation 'properties') { return Get-Field $Operation 'properties' }
    return $Operation
}

function Get-ErrorMessage {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return Protect-Text $Value }
    if (Test-Field $Value 'value') { return Protect-Text ([string](Get-Field $Value 'value')) }
    return (Protect-Data $Value | ConvertTo-Json -Depth 80 -Compress)
}

function Add-ErrorEntry {
    param($List, [string]$Source, [string]$Name, $Indexes, $ErrorValue, [string]$FallbackCode = '')
    if ($null -eq $ErrorValue -and -not $FallbackCode) { return }
    $details = $ErrorValue
    for ($i = 0; $i -lt 8; $i++) {
        if ((Test-Field $ErrorValue 'message') -or -not (Test-Field $ErrorValue 'error')) { break }
        $ErrorValue = Get-Field $ErrorValue 'error'
    }
    $code = [string](Get-Field $ErrorValue 'code')
    if (-not $code) { $code = $FallbackCode }
    $message = Get-ErrorMessage (Get-Field $ErrorValue 'message')
    if ($ErrorValue -is [string]) { $message = Protect-Text $ErrorValue }
    $List.Add([pscustomobject]@{
        Source = $Source; Name = $Name; RepetitionIndexes = $Indexes
        Code = (Protect-Text $code); Message = $message; Details = (Protect-Data $details)
    })
}

function Add-OperationErrors {
    param($List, $Properties, [string]$Source, [string]$Name, $Indexes, $Payload)
    $errorValue = Get-Field $Properties 'error'
    $failed = (Get-Field $Properties 'status') -in @('Failed', 'Faulted', 'TimedOut', 'Aborted', 'Cancelled', 'Terminated')
    $code = ''
    if ($failed) { $code = [string](Get-Field $Properties 'code') }
    Add-ErrorEntry $List $Source $Name $Indexes $errorValue $code
    if ($null -ne $Payload -and $Payload.Availability -eq 'Available' -and $failed) {
        $output = $Payload.Content
        $body = $output
        if (Test-Field $output 'body') { $body = Get-Field $output 'body' }
        if ($body -is [string]) {
            try { $body = ConvertFrom-ServiceJson $body }
            catch { $body = [pscustomobject]@{ message = $body } }
        }
        $bodyError = Get-Field $body 'error'
        if ($null -ne $bodyError) { Add-ErrorEntry $List ($Source + 'Output') $Name $Indexes $bodyError }
        elseif (Test-Field $body 'message') { Add-ErrorEntry $List ($Source + 'Output') $Name $Indexes $body $code }
        elseif (Test-Field $output 'error') { Add-ErrorEntry $List ($Source + 'Output') $Name $Indexes (Get-Field $output 'error') }
    }
    foreach ($retry in (Get-Field $Properties 'retryHistory')) {
        if ($null -eq $retry) { continue }
        Add-ErrorEntry $List ($Source + 'Retry') $Name $Indexes (Get-Field $retry 'error')
    }
}

function Get-OperationDetail {
    param($Operation, [string]$Name, [string]$Source, $Issues, $ErrorList)
    $properties = Get-OperationProperties $Operation
    $indexes = Get-Field $properties 'repetitionIndexes'
    $inputs = $null
    $outputs = $null
    if ($All -or ($CallingRecordId -and $Source -eq 'Trigger')) {
        $inputs = Get-Payload $properties 'inputs'
        Add-PayloadIssue $Issues "$Source/$Name/inputs" $inputs
    }
    $failed = (Get-Field $properties 'status') -in @('Failed', 'Faulted', 'TimedOut', 'Aborted', 'Cancelled', 'Terminated')
    if ($All -or ($CallingRecordId -and $Source -eq 'Trigger') -or ($Errors -and $failed)) {
        $outputs = Get-Payload $properties 'outputs'
        Add-PayloadIssue $Issues "$Source/$Name/outputs" $outputs
    }
    if ($Errors -or $All) { Add-OperationErrors $ErrorList $properties $Source $Name $indexes $outputs }
    return [pscustomobject]@{
        Name = $Name; Status = (Get-Field $properties 'status')
        RepetitionIndexes = $indexes; Metadata = $Operation
        Inputs = $inputs; Outputs = $outputs
    }
}

function Get-RepetitionDetails {
    param([string]$Uri, [string]$Name, [string]$Kind, $Issues, $ErrorList)
    try {
        $items = @(Get-Collection $Uri "$Kind collection")
        $details = @(
            foreach ($item in $items) {
                $repetitionName = [string](Get-Field $item 'name')
                Get-OperationDetail $item "$Name/$repetitionName" $Kind $Issues $ErrorList
            }
        )
        return [pscustomobject]@{ Availability = 'Available'; Items = $details }
    }
    catch {
        if ((Get-FailureStatus $_) -eq 401) { throw }
        Add-Issue $Issues "$Kind/$Name" 'UnavailableOrUnsupported' $_.Exception.Message
        return [pscustomobject]@{ Availability = 'UnavailableOrUnsupported'; Items = @() }
    }
}

function Get-RunActions {
    param($Run, [string]$RunUri, $Definition, $Issues, $ErrorList)
    $actions = @{}
    $index = @{}
    $definitionObject = Get-Field (Get-Field $Definition.Flow 'properties') 'definition'
    if ($null -ne $definitionObject) { Get-ActionDefinitions $definitionObject $index }
    else {
        Add-Issue $Issues 'ActionDefinitions' 'Unavailable' 'Nested/loop coverage cannot be established from the current flow definition.'
    }
    foreach ($entry in @(Get-Entries (Get-Field (Get-Field $Run 'properties') 'actions'))) {
        $actions[$entry.Name] = [pscustomobject]@{ name = $entry.Name; properties = $entry.Value }
    }
    try {
        foreach ($action in @(Get-Collection "$RunUri/actions?$apiVersion" 'Action collection')) {
            $name = [string](Get-Field $action 'name')
            if (-not $name) { throw 'Action collection returned an unnamed action.' }
            $actions[$name] = $action
        }
    }
    catch {
        if ((Get-FailureStatus $_) -eq 401) { throw }
        Add-Issue $Issues 'Actions' 'ExpandedOnly' $_.Exception.Message
    }
    foreach ($name in @($index.Keys)) {
        if ($actions.ContainsKey($name)) { continue }
        $encodedName = [uri]::EscapeDataString($name)
        try { $actions[$name] = Get-ServiceJson "$RunUri/actions/$encodedName`?$apiVersion" 'Nested action detail' }
        catch {
            if ((Get-FailureStatus $_) -eq 401) { throw }
            Add-Issue $Issues "Action/$name" 'NotReturned' $_.Exception.Message
        }
    }
    foreach ($name in @($actions.Keys | Sort-Object)) {
        $action = $actions[$name]
        $detail = Get-OperationDetail $action $name 'Action' $Issues $ErrorList
        $encodedName = [uri]::EscapeDataString($name)
        $actionDefinition = $null
        if ($index.ContainsKey($name)) { $actionDefinition = $index[$name] }
        $properties = Get-OperationProperties $action
        # A current definition cannot prove a historical action's loop/scope shape.
        $repetitions = Get-RepetitionDetails "$RunUri/actions/$encodedName/repetitions?$apiVersion" $name 'ActionRepetition' $Issues $ErrorList
        $scopeRepetitions = Get-RepetitionDetails "$RunUri/actions/$encodedName/scopeRepetitions?$apiVersion" $name 'ScopeRepetition' $Issues $ErrorList
        foreach ($check in @(
            @{ Field = 'repetitionCount'; Result = $repetitions },
            @{ Field = 'iterationCount'; Result = $scopeRepetitions }
        )) {
            $expected = 0L
            if ([long]::TryParse([string](Get-Field $properties $check.Field), [ref]$expected) -and
                $expected -gt 0 -and $check.Result.Availability -eq 'Available' -and
                $check.Result.Items.Count -lt $expected) {
                Add-Issue $Issues "Action/$name/$($check.Field)" 'CountMismatch' 'Fewer repetitions were returned than the action metadata reports.'
            }
        }
        $path = $name
        if ($null -ne $actionDefinition) { $path = $actionDefinition.Path }
        [pscustomobject]@{
            Name = $name; DefinitionPath = $path; Detail = $detail
            Repetitions = $repetitions; ScopeRepetitions = $scopeRepetitions
        }
    }
}

function Get-Literal {
    param($Value)
    if ($Value -is [string] -and $Value -and $Value -notmatch '^@') { return $Value }
    return $null
}

function Get-TriggerContext {
    param($TriggerDetail, $Definition)
    $runtime = $null
    if ($null -ne $TriggerDetail.Inputs -and $TriggerDetail.Inputs.Availability -eq 'Available') {
        $runtime = $TriggerDetail.Inputs.Content
    }
    $current = Get-Field (Get-Field (Get-Field (Get-Field $Definition.Flow 'properties') 'definition') 'triggers') $TriggerDetail.Name
    $runtimeHost = Get-Field $runtime 'host'
    $hostInfo = $runtimeHost
    $evidence = 'RuntimeInputs'
    if ($null -eq $hostInfo) {
        $hostInfo = Get-Field (Get-Field $current 'inputs') 'host'
        $evidence = 'CurrentDefinition'
    }
    $apiId = [string](Get-Field $hostInfo 'apiId')
    $reference = [string](Get-Field $hostInfo 'connectionReferenceName')
    if (-not $reference) { $reference = [string](Get-Field $hostInfo 'connectionName') }
    if (-not $apiId -and $reference) {
        $references = Get-Field (Get-Field $Definition.Flow 'properties') 'connectionReferences'
        $connection = Get-Field $references $reference
        $apiId = [string](Get-Field $connection 'id')
        if (-not $apiId) { $apiId = [string](Get-Field (Get-Field $connection 'api') 'name') }
        if ($evidence -eq 'RuntimeInputs') { $evidence = 'RuntimeConnectionReferenceWithCurrentBinding' }
    }
    $operation = [string](Get-Field $hostInfo 'operationId')
    $parameters = Get-Field $runtime 'parameters'
    $table = Get-Literal (Get-Field $parameters 'subscriptionRequest/entityname')
    if (-not $table) { $table = Get-Literal (Get-Field (Get-Field $parameters 'subscriptionRequest') 'entityname') }
    if (-not $table) { $table = Get-Literal (Get-Field $parameters 'entityName') }
    if (-not $table) { $table = Get-Literal (Get-Field $parameters 'entityname') }
    if (-not $table) { $table = Get-Literal (Get-Field $parameters 'table') }
    return [pscustomobject]@{
        ApiId = $apiId; Operation = $operation; Evidence = $evidence
        Parameters = $parameters; Table = $table
    }
}

function Get-DataverseKey {
    param([string]$Table)
    if (-not $Table) { return $null }
    if ($DataversePrimaryKey.ContainsKey($Table)) {
        return [pscustomobject]@{ Attribute = $DataversePrimaryKey[$Table]; Source = 'ExplicitPrimaryKeyMap' }
    }
    if ($metadataCache.ContainsKey($Table)) { return $metadataCache[$Table] }
    if ($null -eq $DataverseUrl) { return $null }
    if ($Table -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw 'Dataverse table name is not a literal schema name.' }
    $filter = [uri]::EscapeDataString("EntitySetName eq '$Table' or LogicalName eq '$Table'")
    $origin = $DataverseUrl.GetLeftPart([UriPartial]::Authority)
    $uri = "$origin/api/data/v9.2/EntityDefinitions?`$select=LogicalName,EntitySetName,PrimaryIdAttribute&`$filter=$filter"
    $matches = @(Get-Collection $uri 'Dataverse primary-key metadata' 'Dataverse')
    if ($matches.Count -ne 1 -or -not (Get-Field $matches[0] 'PrimaryIdAttribute')) {
        throw 'Dataverse metadata did not identify exactly one table and primary key.'
    }
    $result = [pscustomobject]@{ Attribute = (Get-Field $matches[0] 'PrimaryIdAttribute'); Source = 'DataverseMetadata' }
    $metadataCache[$Table] = $result
    return $result
}

function Get-CallingRecord {
    param($TriggerDetail, $Definition)
    $context = Get-TriggerContext $TriggerDetail $Definition
    $record = [ordered]@{
        Source = $null; RecordId = $null; Availability = 'Unsupported'
        Table = $context.Table; PrimaryKey = $null; SiteUrl = $null; ListId = $null
        ItemId = $null; UniqueId = $null; Evidence = $null
        ConnectorEvidence = $context.Evidence; TriggerOperation = $context.Operation; Reason = ''
    }
    $apiName = ($context.ApiId -split '/')[-1]
    if ($apiName -in @('shared_commondataserviceforapps', 'shared_commondataservice', 'commondataserviceforapps', 'commondataservice')) {
        $record.Source = 'Dataverse'
    }
    elseif ($apiName -in @('shared_sharepointonline', 'sharepointonline')) { $record.Source = 'SharePoint' }
    else {
        $record.Reason = 'The trigger is not an identified Dataverse row or SharePoint item connector.'
        return [pscustomobject]$record
    }
    if ($record.Source -notin $RecordSource) {
        $record.Availability = 'Excluded'
        $record.Reason = 'The identified connector is excluded by RecordSource.'
        return [pscustomobject]$record
    }
    if ($context.Evidence -eq 'CurrentDefinition') {
        $record.Availability = 'UnverifiedConnector'
        $record.Reason = 'Only the current definition identifies the connector. It cannot prove the historical trigger type; no ID is guessed.'
        return [pscustomobject]$record
    }
    if ($null -eq $TriggerDetail.Outputs -or $TriggerDetail.Outputs.Availability -ne 'Available') {
        $record.Availability = 'Unavailable'
        $record.Reason = 'The trigger output is not available; no record ID can be recovered.'
        return [pscustomobject]$record
    }
    $body = $TriggerDetail.Outputs.Content
    if (Test-Field $body 'body') { $body = Get-Field $body 'body' }
    if (-not $record.Table) {
        $odataContext = [string](Get-Field $body '@odata.context')
        if ($odataContext -match '#([A-Za-z_][A-Za-z0-9_]*)(?:/\$entity)?$') { $record.Table = $Matches[1] }
    }
    $values = Get-Field $body 'value'
    $hasMappedKey = $record.Table -and $DataversePrimaryKey.ContainsKey([string]$record.Table) -and
        (Test-Field $body $DataversePrimaryKey[$record.Table])
    if ($values -is [array] -and -not (Test-Field $body 'ID') -and
        -not (Test-Field $body '@odata.id') -and -not (Test-Field $body '@odata.editLink') -and -not $hasMappedKey) { $body = $values }
    if ($body -is [array]) {
        if ($body.Count -ne 1) {
            $record.Availability = 'Ambiguous'
            $record.Reason = 'The trigger returned a batch, not one unambiguous calling record.'
            return [pscustomobject]$record
        }
        $body = $body[0]
    }
    if ($record.Source -eq 'Dataverse') {
        $allowed = @('SubscribeWebhookTrigger', 'SubscribeWebhookTriggerWithOrganization',
            'OnNewItems', 'OnUpdatedItems', 'OnDeletedItems')
        if ($context.Operation -notin $allowed) {
            $record.Reason = 'This Dataverse trigger operation is not a supported row-change trigger.'
            return [pscustomobject]$record
        }
        $candidates = [System.Collections.Generic.List[object]]::new()
        foreach ($field in @('@odata.id', '@odata.editLink')) {
            $canonical = [string](Get-Field $body $field)
            if ($canonical -match '(?:^|/)([A-Za-z_][A-Za-z0-9_]*)\(([0-9a-fA-F-]{36})\)$') {
                $record.Table = $Matches[1]
                $candidates.Add([pscustomobject]@{ Id = $Matches[2]; Evidence = $field })
            }
        }
        if ((Get-Field $body 'PrimaryEntityName') -and (Get-Field $body 'PrimaryEntityId')) {
            $candidates.Add([pscustomobject]@{
                Id = [string](Get-Field $body 'PrimaryEntityId'); Evidence = 'DataverseRemoteExecutionContext.PrimaryEntityId'
            })
            $record.Table = [string](Get-Field $body 'PrimaryEntityName')
        }
        if ($candidates.Count -eq 0 -or $DataversePrimaryKey.ContainsKey([string]$context.Table) -or
            $DataversePrimaryKey.ContainsKey([string]$record.Table)) {
            $keyTable = $record.Table
            if ($context.Table -and (-not $DataversePrimaryKey.ContainsKey([string]$record.Table) -or
                    $DataversePrimaryKey.ContainsKey([string]$context.Table))) { $keyTable = $context.Table }
            try { $key = Get-DataverseKey $keyTable }
            catch {
                $record.Availability = 'Unavailable'
                $record.Reason = Protect-Text $_.Exception.Message
                return [pscustomobject]$record
            }
            if ($null -ne $key) {
                $record.PrimaryKey = $key.Attribute
                $candidates.Add([pscustomobject]@{ Id = [string](Get-Field $body $key.Attribute); Evidence = $key.Source })
            }
        }
        $valid = @(
            foreach ($candidate in $candidates) {
                $guid = [guid]::Empty
                if ([guid]::TryParse($candidate.Id, [ref]$guid) -and $guid -ne [guid]::Empty) {
                    [pscustomobject]@{ Id = $guid.ToString(); Evidence = $candidate.Evidence }
                }
            }
        )
        $distinct = @($valid | Select-Object -ExpandProperty Id -Unique)
        if ($distinct.Count -gt 1) {
            $record.Availability = 'Ambiguous'
            $record.Reason = 'Canonical/primary-key row identities disagree; no ID was selected.'
        }
        elseif ($distinct.Count -eq 1) {
            $record.RecordId = $distinct[0]
            $record.Evidence = $valid[0].Evidence
            $record.Availability = 'Available'
            $record.Reason = 'Canonical row identity or an explicitly verified primary key; lookup GUIDs were not inspected.'
        }
        else {
            $record.Availability = 'Unknown'
            $record.Reason = 'No canonical row ID/known primary key was present. Supply DataversePrimaryKey or DataverseUrl plus metadata authentication.'
        }
    }
    else {
        $allowed = @('GetOnNewItems', 'GetOnUpdatedItems', 'GetOnChangedItems',
            'GetOnNewFileItems', 'GetOnUpdatedFileItems', 'GetOnDeletedFileItems', 'GetOnDeletedItems')
        if ($context.Operation -notin $allowed) {
            $record.Reason = 'This SharePoint trigger operation is not a supported item/file-change trigger.'
            return [pscustomobject]$record
        }
        $record.SiteUrl = Get-Literal (Get-Field $context.Parameters 'dataset')
        $record.ListId = Get-Literal (Get-Field $context.Parameters 'table')
        $item = [string](Get-Field $body 'ID')
        $number = 0L
        if ([long]::TryParse($item, [ref]$number) -and $number -gt 0) {
            $record.ItemId = $number.ToString([Globalization.CultureInfo]::InvariantCulture)
            $record.RecordId = $record.ItemId
            $record.Availability = 'Available'
            $record.Evidence = 'SharePointTrigger.ID'
            $record.Reason = 'List item ID, scoped to SiteUrl/ListId; not a file identifier, lookup ID, or list GUID.'
        }
        else {
            $record.Availability = 'Unknown'
            $record.Reason = 'No numeric top-level SharePoint item ID was returned.'
        }
        $unique = [guid]::Empty
        $uniqueValue = Get-Field $body 'UniqueId'
        if (-not $uniqueValue) { $uniqueValue = Get-Field $body '{UniqueId}' }
        if ([guid]::TryParse([string]$uniqueValue, [ref]$unique) -and $unique -ne [guid]::Empty) {
            $record.UniqueId = $unique.ToString()
        }
    }
    return [pscustomobject]$record
}

function Test-RunSelection {
    param($Run)
    $properties = Get-Field $Run 'properties'
    $runStatus = [string](Get-Field $properties 'status')
    if ($Status.Count -gt 0 -and $runStatus -notin $Status -and
        -not ('Terminated' -in $Status -and (Get-Field $properties 'code') -eq 'Terminated')) { return $false }
    if ($null -ne $fromUtc -or $null -ne $toUtc) {
        $start = ConvertTo-UtcDate (Get-Field $properties 'startTime') 'Service run startTime'
        if ($null -ne $fromUtc -and $start -lt $fromUtc) { return $false }
        if ($null -ne $toUtc -and $start -ge $toUtc) { return $false }
    }
    return $true
}

function ConvertTo-ExportJson {
    param($Value)
    return ConvertTo-Json -InputObject (Protect-Data $Value) -Depth 100 -Compress
}

function Get-ExportTime {
    param($Properties, [string]$Name)
    $value = Get-Field $Properties $Name
    if ($value) { return (ConvertTo-UtcDate $value "Service $Name").ToString('o') }
    return $null
}

function Get-ExportDuration {
    param($Properties)
    $start = Get-Field $Properties 'startTime'
    $end = Get-Field $Properties 'endTime'
    if ($start -and $end) {
        $seconds = ((ConvertTo-UtcDate $end 'Service endTime') - (ConvertTo-UtcDate $start 'Service startTime')).TotalSeconds
        return $seconds.ToString('0.#######', [Globalization.CultureInfo]::InvariantCulture)
    }
    return $null
}

function New-CsvRow {
    $row = [ordered]@{}
    if ($IdOnly) { $row['RecordId'] = $null }
    else { foreach ($column in $csvColumns) { $row[$column] = $null } }
    return $row
}

function ConvertTo-CsvOperationRow {
    param($Result, $Context, [string]$RowType, $Detail, [string]$DefinitionPath = '',
        [string]$ActionName = '', $Action = $null)
    $row = New-CsvRow
    $runProperties = Get-Field $Context.Run 'properties'
    $operation = $Context.Run
    if ($null -ne $Detail) { $operation = $Detail.Metadata }
    $properties = Get-OperationProperties $operation
    $correlation = Get-Field $properties 'correlation'
    $runCorrelation = Get-Field $runProperties 'correlation'
    $row.RowType = $RowType
    foreach ($field in @('TenantId', 'Cloud', 'EnvironmentName', 'FlowId', 'RunId')) { $row[$field] = Get-Field $Result $field }
    $row.FlowDisplayName = $Context.FlowDisplayName
    $row.RunStatus = Get-Field $runProperties 'status'
    $row.RunStartTimeUtc = Get-ExportTime $runProperties 'startTime'
    $row.RunEndTimeUtc = Get-ExportTime $runProperties 'endTime'
    $row.RunDurationSeconds = Get-ExportDuration $runProperties
    $row.OperationName = $row.RunId
    if ($null -ne $Detail) { $row.OperationName = $Detail.Name }
    if ($ActionName) {
        $row.OperationName = $ActionName
        $row.RepetitionName = $Detail.Name.Substring($ActionName.Length + 1)
    }
    $row.DefinitionPath = $DefinitionPath
    $row.OperationId = Get-Field $operation 'id'
    $row.Status = Get-Field $properties 'status'
    $row.Code = Get-Field $properties 'code'
    $row.StartTimeUtc = Get-ExportTime $properties 'startTime'
    $row.EndTimeUtc = Get-ExportTime $properties 'endTime'
    $row.DurationSeconds = Get-ExportDuration $properties
    $row.ClientTrackingId = Get-Field $correlation 'clientTrackingId'
    if (-not $row.ClientTrackingId) { $row.ClientTrackingId = Get-Field $runCorrelation 'clientTrackingId' }
    $row.TrackingId = Get-Field $properties 'trackingId'
    $row.ActionTrackingId = Get-Field $correlation 'actionTrackingId'
    foreach ($field in @('ClientRequestId', 'ServiceRequestId')) {
        $row[$field] = Get-Field $properties $field
        if (-not $row[$field]) { $row[$field] = Get-Field $correlation $field }
    }
    $row.RepetitionIndexesJson = ConvertTo-ExportJson (Get-Field $properties 'repetitionIndexes')
    foreach ($side in @('Inputs', 'Outputs')) {
        $payload = Get-Field $Detail $side
        $row[$side + 'Availability'] = 'NotRequested'
        if ($null -ne $payload) {
            $row[$side + 'Availability'] = $payload.Availability
            $row[$side + 'Reason'] = $payload.Reason
            if ($payload.Availability -eq 'Available') { $row[$side + 'Json'] = ConvertTo-ExportJson $payload.Content }
        }
    }
    if ($null -ne $Action) {
        $row.RepetitionsAvailability = $Action.Repetitions.Availability
        $row.ScopeRepetitionsAvailability = $Action.ScopeRepetitions.Availability
    }
    $operationError = Get-Field $properties 'error'
    $row.ErrorCode = Get-Field $operationError 'code'
    $row.ErrorMessage = Get-ErrorMessage (Get-Field $operationError 'message')
    $allErrors = Get-Field $Result 'Errors'
    $relatedErrors = @(
        foreach ($entry in $allErrors) {
            if ($RowType -eq 'Run' -or
                ($entry.Name -eq $Detail.Name -and $entry.Source.StartsWith($RowType, [StringComparison]::Ordinal))) { $entry }
        }
    )
    if ($RowType -ne 'Run') {
        $messages = @($relatedErrors | Where-Object { $_.Source -eq ($RowType + 'Output') -and $_.Message })
        if ($messages.Count -eq 0) { $messages = @($relatedErrors | Where-Object { $_.Message }) }
        if ($messages.Count -gt 0) {
            $row.ErrorCode = $messages[0].Code
            $row.ErrorMessage = $messages[0].Message
        }
    }
    $row.ErrorsJson = ConvertTo-ExportJson $relatedErrors
    $row.DetailCoverage = Get-Field $Result 'DetailCoverage'
    if (-not $row.DetailCoverage) { $row.DetailCoverage = 'SummaryOnly' }
    $row.IssuesJson = ConvertTo-ExportJson (Get-Field $Result 'Issues')
    $record = Get-Field $Result 'CallingRecord'
    foreach ($field in @('RecordId', 'Table', 'PrimaryKey', 'SiteUrl', 'ListId', 'ItemId', 'UniqueId',
            'ConnectorEvidence', 'TriggerOperation')) { $row[$field] = Get-Field $record $field }
    $row.RecordSource = Get-Field $record 'Source'
    $row.RecordAvailability = Get-Field $record 'Availability'
    $row.RecordEvidence = Get-Field $record 'Evidence'
    $row.RecordReason = Get-Field $record 'Reason'
    $row.CallingRecordJson = ConvertTo-ExportJson $record
    $row.RunCorrelationJson = ConvertTo-ExportJson $runCorrelation
    $row.CorrelationJson = ConvertTo-ExportJson $correlation
    $row.RetryHistoryJson = ConvertTo-ExportJson (Get-Field $properties 'retryHistory')
    $row.MetadataJson = ConvertTo-ExportJson $operation
    $row.DefinitionEvidence = Get-Field $Result 'DefinitionEvidence'
    return Protect-Data ([pscustomobject]$row)
}

function ConvertTo-CsvRows {
    param($Result, $Context)
    if ($IdOnly) { return [pscustomobject]@{ RecordId = [string]$Result } }
    if ($CallingRecordId -and -not ($All -or $Errors)) {
        $row = ConvertTo-CsvOperationRow $Result $Context 'Run' $null
        foreach ($field in @('MetadataJson', 'ErrorsJson', 'ErrorCode', 'ErrorMessage', 'RetryHistoryJson')) { $row.$field = $null }
        return $row
    }
    ConvertTo-CsvOperationRow $Result $Context 'Run' $null
    if ($null -ne $Context.Trigger) {
        ConvertTo-CsvOperationRow $Result $Context 'Trigger' $Context.Trigger
    }
    foreach ($action in $Context.Actions) {
        ConvertTo-CsvOperationRow $Result $Context 'Action' $action.Detail $action.DefinitionPath '' $action
        foreach ($kind in @('Repetitions', 'ScopeRepetitions')) {
            $type = 'ActionRepetition'
            if ($kind -eq 'ScopeRepetitions') { $type = 'ScopeRepetition' }
            foreach ($repetition in $action.$kind.Items) {
                ConvertTo-CsvOperationRow $Result $Context $type $repetition $action.DefinitionPath $action.Name
            }
        }
    }
}

function Add-ExportPath {
    param([string]$Path, [string]$Kind)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Kind export path cannot be empty." }
    $provider = $null; $drive = $null
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path, [ref]$provider, [ref]$drive)
    if ($provider.Name -ne 'FileSystem') { throw "$Kind export path must use the FileSystem provider." }
    $resolved = [IO.Path]::GetFullPath($resolved)
    if (-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($resolved))) {
        throw "$Kind export parent directory must already exist."
    }
    if ([IO.File]::Exists($resolved) -or [IO.Directory]::Exists($resolved)) {
        throw "$Kind export destination already exists; choose a new file. Nothing will be overwritten."
    }
    $comparison = [StringComparison]::Ordinal
    if ([IO.Path]::DirectorySeparatorChar -eq '\') { $comparison = [StringComparison]::OrdinalIgnoreCase }
    foreach ($entry in $exportFiles) {
        if ([string]::Equals($resolved, $entry.Path, $comparison)) { throw 'CsvPath and JsonPath must name different files.' }
    }
    $exportFiles.Add([pscustomobject]@{
        Kind = $Kind; Path = $resolved; TemporaryPath = $null
        Created = $false; Stream = $null; Writer = $null; Published = $false
    })
}

function Initialize-ExportFiles {
    foreach ($entry in $exportFiles) {
        $entry.TemporaryPath = Join-Path ([IO.Path]::GetDirectoryName($entry.Path)) ('.flow-history-' + [guid]::NewGuid().ToString('N') + '.partial')
        $entry.Stream = [IO.File]::Open($entry.TemporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $entry.Created = $true
        $encoding = [Text.UTF8Encoding]::new(($entry.Kind -eq 'CSV'))
        $entry.Writer = [IO.StreamWriter]::new($entry.Stream, $encoding)
        if ($entry.Kind -eq 'JSON') { $entry.Writer.Write('[') }
        else {
            $header = @([pscustomobject](New-CsvRow) | ConvertTo-Csv @csvParameters)[0]
            $entry.Writer.WriteLine($header)
        }
    }
}

function Complete-ExportFiles {
    foreach ($entry in $exportFiles) {
        if ($entry.Kind -eq 'JSON') {
            if ($exportResultCount -gt 0) { $entry.Writer.WriteLine() }
            $entry.Writer.WriteLine(']')
        }
        $entry.Writer.Dispose()
        $entry.Writer = $null
        $entry.Stream = $null
    }
    foreach ($entry in $exportFiles) {
        if ([IO.File]::Exists($entry.Path) -or [IO.Directory]::Exists($entry.Path)) {
            throw 'An export destination appeared during retrieval. Existing files were preserved and no staged export was published.'
        }
    }
    try {
        foreach ($entry in $exportFiles) {
            [IO.File]::Move($entry.TemporaryPath, $entry.Path)
            $entry.Published = $true
        }
    }
    catch {
        $published = @($exportFiles | Where-Object Published | Select-Object -ExpandProperty Path)
        $message = 'Export publication failed; existing destinations were not overwritten.'
        if ($published.Count -gt 0) {
            $message += ' These files were already published with complete results: ' + ($published -join ', ') + '.'
        }
        throw [IO.IOException]::new($message, $_.Exception)
    }
}

function Write-RunResult {
    param($Run, $Flow, [bool]$AlreadyDetailed)
    $context = @{ Run = $null; Trigger = $null; Actions = @(); FlowDisplayName = $null }
    foreach ($result in @(Convert-RunResult $Run $Flow $AlreadyDetailed $context)) {
        foreach ($entry in $exportFiles) {
            if ($entry.Kind -eq 'JSON') {
                if ($exportResultCount -gt 0) { $entry.Writer.WriteLine(',') }
                else { $entry.Writer.WriteLine() }
                $entry.Writer.Write((ConvertTo-ExportJson $result))
            }
            else {
                foreach ($row in (ConvertTo-CsvRows $result $context)) {
                    $record = @(ConvertTo-Csv -InputObject $row @csvParameters)[1]
                    $entry.Writer.WriteLine($record)
                }
            }
        }
        $script:exportResultCount++
        $result
    }
}

function Convert-RunResult {
    param($Run, $Flow, [bool]$AlreadyDetailed, [hashtable]$ExportContext)
    $id = [string](Get-Field $Flow 'name')
    $runName = [string](Get-Field $Run 'name')
    if (-not $runName) { throw 'A run did not contain its run name.' }
    $runUri = "$normalRoot/flows/$id/runs/$([uri]::EscapeDataString($runName))"
    $issues = [System.Collections.Generic.List[object]]::new()
    $errorList = [System.Collections.Generic.List[object]]::new()
    if (($All -or $Errors -or $CallingRecordId) -and -not $AlreadyDetailed) {
        $expand = ''
        if ($All -or $Errors) { $expand = '&$expand=properties%2Factions' }
        try { $Run = Get-ServiceJson "$runUri`?$apiVersion$expand" 'Run detail' }
        catch {
            if ((Get-FailureStatus $_) -eq 401) { throw }
            Add-Issue $issues 'RunDetail' 'Unavailable' $_.Exception.Message
        }
    }
    $properties = Get-Field $Run 'properties'
    $ExportContext.Run = $Run
    $result = [ordered]@{
        TenantId = $TenantId.ToString(); Cloud = $cloudProfile.Name; EnvironmentName = $EnvironmentName; FlowId = $id
        FlowDisplayName = (Get-Field (Get-Field $Flow 'properties') 'displayName')
        RunId = $runName; Status = (Get-Field $properties 'status')
        StartTime = $null; EndTime = $null
    }
    foreach ($timeField in @('StartTime', 'EndTime')) {
        $timeValue = Get-Field $properties $timeField
        if ($timeValue) { $result[$timeField] = (ConvertTo-UtcDate $timeValue "Service $timeField").ToString('o') }
    }
    if (-not ($All -or $Errors -or $CallingRecordId)) {
        if (($CsvPath -or $JsonPath) -and -not $result.FlowDisplayName) {
            $flowMetadata = Get-FlowDefinition $id
            $result.FlowDisplayName = Get-Field (Get-Field $flowMetadata.Flow 'properties') 'displayName'
            if ($flowMetadata.Availability -ne 'Available') {
                Write-Warning "Flow display name unavailable for $id; export retains its FlowId. $($flowMetadata.Reason)"
            }
        }
        $ExportContext.FlowDisplayName = $result.FlowDisplayName
        return [pscustomobject]$result
    }
    $definition = Get-FlowDefinition $id
    $knownDisplayName = Get-Field (Get-Field $definition.Flow 'properties') 'displayName'
    if ($knownDisplayName) { $result.FlowDisplayName = $knownDisplayName }
    $ExportContext.FlowDisplayName = $result.FlowDisplayName
    if ($definition.Availability -ne 'Available') {
        Add-Issue $issues 'FlowDefinition' $definition.Availability $definition.Reason
    }
    $trigger = Get-Field $properties 'trigger'
    $triggerName = [string](Get-Field $trigger 'name')
    $triggerDetail = Get-OperationDetail $trigger $triggerName 'Trigger' $issues $errorList
    $ExportContext.Trigger = $triggerDetail
    if ($All -or $Errors) {
        Add-OperationErrors $errorList $properties 'Run' $runName $null $null
        $actions = @(Get-RunActions $Run $runUri $definition $issues $errorList)
        $ExportContext.Actions = $actions
        if ($All) {
            $result.Run = $Run
            $result.Trigger = $triggerDetail
            $result.Actions = $actions
            $result.DefinitionEvidence = $definition.Reason
        }
        $result.Errors = @($errorList.ToArray())
    }
    if ($CallingRecordId) {
        $record = Get-CallingRecord $triggerDetail $definition
        if ($IdOnly) {
            if ($record.Availability -eq 'Available') { return $record.RecordId }
            Write-Warning "No calling record ID for flow $id run $runName ($($record.Availability)): $($record.Reason)"
            return
        }
        if (-not ($All -or $Errors)) {
            $result = [ordered]@{ TenantId = $TenantId.ToString(); Cloud = $cloudProfile.Name; EnvironmentName = $EnvironmentName; FlowId = $id; RunId = $runName }
        }
        $result.CallingRecord = $record
        if ($record.Availability -in @('Unknown', 'Unavailable', 'Ambiguous', 'UnverifiedConnector')) {
            Add-Issue $issues 'CallingRecord' $record.Availability $record.Reason
        }
    }
    $result.DetailCoverage = 'AvailableServiceData'
    if ($issues.Count -gt 0) { $result.DetailCoverage = 'Partial' }
    $result.Issues = @($issues.ToArray())
    return Protect-Data ([pscustomobject]$result)
}

try {
    $cloudProfile = Get-CloudProfile $Cloud
    $flowAudience = $cloudProfile.Audience
    $apiBase = [uri]$cloudProfile.ApiBase
    if ($null -eq $FlowId) { $FlowId = @() }
    if ($null -eq $RunId) { $RunId = @() }
    if ($null -eq $Status) { $Status = @() }
    if ($TenantId -eq [guid]::Empty) { throw 'TenantId cannot be the empty GUID.' }
    if ($EnvironmentName -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$') { throw 'EnvironmentName must be an environment resource name.' }
    if ($AllFlows -and $FlowId.Count -gt 0) { throw 'AllFlows and FlowId cannot be combined.' }
    if ($supplied.ContainsKey('FlowId') -and $FlowId.Count -eq 0) { throw 'FlowId cannot be an empty array.' }
    if ($supplied.ContainsKey('RunId') -and $RunId.Count -eq 0) { throw 'RunId cannot be an empty array.' }
    if ($supplied.ContainsKey('Status') -and $Status.Count -eq 0) { throw 'Status cannot be an empty array; omit it for any status.' }
    if ($CallingRecordId -and @($RecordSource).Count -eq 0) { throw 'RecordSource cannot be an empty array.' }
    if ($IdOnly -and (-not $CallingRecordId -or $All -or $Errors)) { throw 'IdOnly requires CallingRecordId without All or Errors.' }
    if ($supplied.ContainsKey('RecordSource') -and -not $CallingRecordId) { throw 'RecordSource requires CallingRecordId.' }
    if ($null -ne $AccessToken -and $UseExistingContext) { throw 'AccessToken and UseExistingContext cannot be combined.' }
    if ($DeviceCode -and ($null -ne $AccessToken -or $UseExistingContext)) {
        throw 'DeviceCode cannot be combined with AccessToken or UseExistingContext.'
    }
    if ($supplied.ContainsKey('LastDays') -and ($From -or $To)) { throw 'LastDays cannot be combined with From or To.' }
    foreach ($dateParameter in @('From', 'To')) {
        if ($supplied.ContainsKey($dateParameter) -and [string]::IsNullOrWhiteSpace([string]$supplied[$dateParameter])) {
            throw "$dateParameter cannot be empty; omit it for an open date boundary."
        }
    }
    if ($null -ne $DataverseAccessToken -and $null -eq $DataverseUrl) { throw 'DataverseAccessToken requires DataverseUrl.' }
    if ($null -ne $DataverseUrl -and
        ($DataverseUrl.Scheme -ne 'https' -or $DataverseUrl.Port -ne 443 -or
         $DataverseUrl.UserInfo -or $DataverseUrl.Query -or $DataverseUrl.Fragment -or $DataverseUrl.AbsolutePath -ne '/')) {
        throw 'DataverseUrl must be an explicit HTTPS organization origin with no path, query, credentials, or nonstandard port.'
    }
    if ($null -ne $DataverseUrl -and $DataverseUrl.DnsSafeHost -notmatch $cloudProfile.DataversePattern) {
        throw 'DataverseUrl is not a hosted Dataverse organization in the selected cloud. GCC requires an org.crm9.dynamics.com origin; no cross-cloud metadata request was sent.'
    }
    foreach ($table in @($DataversePrimaryKey.Keys)) {
        if ($table -notmatch '^[A-Za-z_][A-Za-z0-9_]*$' -or
            $DataversePrimaryKey[$table] -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            throw 'DataversePrimaryKey must map literal table names to actual primary-key attribute names.'
        }
    }
    $flowIds = @(
        foreach ($id in $FlowId) {
            $guid = [guid]::Empty
            if (-not [guid]::TryParse($id, [ref]$guid) -or $guid -eq [guid]::Empty) { throw 'FlowId must contain nonempty flow resource GUIDs.' }
            $guid.ToString()
        }
    ) | Select-Object -Unique
    $flowIds = @($flowIds)
    $runIds = @(
        foreach ($id in $RunId) {
            if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,255}$') { throw 'RunId must contain run names, not URLs or resource paths.' }
            $id
        }
    ) | Select-Object -Unique
    $runIds = @($runIds)
    $Status = @($Status)
    $fromUtc = $null
    $toUtc = $null
    if ($From) { $fromUtc = ConvertTo-UtcDate $From 'From' }
    if ($To) { $toUtc = ConvertTo-UtcDate $To 'To' }
    if ($supplied.ContainsKey('LastDays')) { $fromUtc = $invocationTime.AddDays(-$LastDays); $toUtc = $invocationTime }
    if ($null -ne $fromUtc -and $null -ne $toUtc -and $fromUtc -ge $toUtc) { throw 'From must be earlier than To.' }
    if ($null -ne $TestApiBaseUri) {
        if (-not $TestApiBaseUri.IsLoopback -or $TestApiBaseUri.Scheme -ne 'http' -or
            $TestApiBaseUri.UserInfo -or $TestApiBaseUri.Query -or $TestApiBaseUri.Fragment -or $TestApiBaseUri.AbsolutePath -ne '/') {
            throw 'TestApiBaseUri is restricted to an HTTP loopback origin for offline tests.'
        }
        $apiBase = $TestApiBaseUri
    }
    if ($supplied.ContainsKey('CsvPath')) { Add-ExportPath $CsvPath 'CSV' }
    if ($supplied.ContainsKey('JsonPath')) { Add-ExportPath $JsonPath 'JSON' }
    if ($null -eq $AccessToken) { Initialize-AzContext }
    $null = Get-ServiceToken 'Flow'
    if ($null -ne $DataverseAccessToken) { $null = Get-ServiceToken 'Dataverse' }
    Initialize-ExportFiles
    Add-Type -AssemblyName System.Net.Http
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $http = [System.Net.Http.HttpClient]::new($handler)
    $http.Timeout = [TimeSpan]::FromSeconds($RequestTimeoutSeconds)
    $http.MaxResponseContentBufferSize = [long]$MaxPayloadMB * 1024 * 1024
    $origin = $apiBase.GetLeftPart([UriPartial]::Authority)
    $normalRoot = "$origin/providers/Microsoft.ProcessSimple/environments/$EnvironmentName"
    $flowRoot = $normalRoot
    if ($AsAdmin) { $flowRoot = "$origin/providers/Microsoft.ProcessSimple/scopes/admin/environments/$EnvironmentName" }
    $flows = @()
    if ($flowIds.Count -gt 0) {
        $flows = @(
            foreach ($id in $flowIds) { [pscustomobject]@{ name = $id; properties = @{ displayName = $null } } }
        )
    }
    elseif ($AsAdmin) {
        $flows = @(Get-Collection "$flowRoot/v2/flows?$apiVersion&include=includeSolutionCloudFlows" 'Admin flow collection')
    }
    else {
        Write-Warning 'Discovery is limited to flows visible to this user. Use AsAdmin for environment-wide admin discovery; history/payload permissions remain separate.'
        $flows = @(
            foreach ($sharing in @('personal', 'team')) {
                $filter = [uri]::EscapeDataString("search('$sharing')")
                Get-Collection "$flowRoot/flows?$apiVersion&include=includeSolutionCloudFlows&`$filter=$filter" 'Visible flow collection'
            }
        )
    }
    $seenFlows = @{}
    $seenRuns = @{}
    $foundRuns = @{}
    $filterParts = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $fromUtc) { $filterParts.Add('startTime ge ' + $fromUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)) }
    if ($null -ne $toUtc) { $filterParts.Add('startTime lt ' + $toUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)) }
    if ($Status.Count -eq 1 -and $Status[0] -in @('Succeeded', 'Failed', 'Cancelled', 'Running')) {
        $filterParts.Add("status eq '$($Status[0])'")
    }
    $filterQuery = ''
    if ($filterParts.Count -gt 0) { $filterQuery = '&$filter=' + [uri]::EscapeDataString(($filterParts -join ' and ')) }
    foreach ($flow in $flows) {
        $id = [string](Get-Field $flow 'name')
        $validatedId = [guid]::Empty
        if (-not [guid]::TryParse($id, [ref]$validatedId)) { throw 'Flow discovery returned an invalid flow resource GUID.' }
        $id = $validatedId.ToString()
        if ($seenFlows.ContainsKey($id)) { continue }
        $seenFlows[$id] = $true
        $flow.name = $id
        if ($runIds.Count -gt 0 -and -not $AsAdmin) {
            foreach ($runName in $runIds) {
                $expand = ''
                if ($All -or $Errors) { $expand = '&$expand=properties%2Factions' }
                try {
                    $run = Get-ServiceJson "$normalRoot/flows/$id/runs/$runName`?$apiVersion$expand" 'Selected run'
                }
                catch {
                    if ((Get-FailureStatus $_) -eq 404) { continue }
                    throw
                }
                $foundRuns[$runName] = $true
                if (Test-RunSelection $run) { Write-RunResult $run $flow $true }
            }
        }
        else {
            # Run ID selection must precede date/status filtering so a filtered-out ID is not reported missing.
            $query = $filterQuery
            if ($runIds.Count -gt 0) { $query = '' }
            foreach ($run in (Get-Collection "$flowRoot/flows/$id/runs?$apiVersion$query" 'Run collection')) {
                $runName = [string](Get-Field $run 'name')
                if (-not $runName) { throw 'Run collection returned an unnamed run.' }
                $key = "$id/$runName"
                if ($seenRuns.ContainsKey($key)) { continue }
                $seenRuns[$key] = $true
                if ($runIds.Count -gt 0) {
                    if ($runName -notin $runIds) { continue }
                    $foundRuns[$runName] = $true
                }
                if (Test-RunSelection $run) { Write-RunResult $run $flow $false }
            }
        }
    }
    $missing = @($runIds | Where-Object { -not $foundRuns.ContainsKey($_) })
    if ($missing.Count -gt 0) {
        throw "Selected run IDs were not found in the selected/visible flows (possibly deleted or outside retention): $($missing -join ', ')."
    }
    Complete-ExportFiles
}
finally {
    if ($null -ne $http) { $http.Dispose() }
    elseif ($null -ne $handler) { $handler.Dispose() }
    foreach ($entry in $exportFiles) {
        try {
            if ($null -ne $entry.Writer) { $entry.Writer.Dispose() }
            elseif ($null -ne $entry.Stream) { $entry.Stream.Dispose() }
            if ($entry.Created -and -not $entry.Published -and [IO.File]::Exists($entry.TemporaryPath)) {
                [IO.File]::Delete($entry.TemporaryPath)
            }
        }
        catch { Write-Warning "Export staging cleanup failed for $($entry.TemporaryPath); remove this private partial file manually." }
    }
}

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ApiRoot = 'https://api.powerplatform.com'
$script:ApiVersion = '2024-10-01'
$script:FormatVersion = 1
$script:Utf8 = [System.Text.UTF8Encoding]::new($false)
$script:FullVisibilityRoles = @(
    '62e90394-69f5-4237-9190-012177145e10', # Global Administrator
    '11648597-926c-4cf3-9c36-bcebb0ba8dcc', # Power Platform Administrator
    '44367163-eba1-44c3-98af-f5787879f96a', # Dynamics 365 Administrator
    'f2ef992c-3afb-46b9-b7cf-a126ee74c451'  # Global Reader
)

function Get-Field {
    param($Value, [string]$Name)
    if ($Value -is [System.Collections.IDictionary] -and $Value.Contains($Name)) {
        return ,$Value[$Name]
    }
    return $null
}

function Get-Sha256 {
    param([string]$Text)
    $stream = [System.IO.MemoryStream]::new($script:Utf8.GetBytes($Text))
    try {
        return (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    finally { $stream.Dispose() }
}

function ConvertFrom-JsonValue {
    param($Value)
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $result = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $result[$property.Name] = ConvertFrom-JsonValue $property.Value
        }
        return $result
    }
    if ($Value -is [System.Collections.IList]) {
        $items = [object[]]::new($Value.Count)
        for ($index = 0; $index -lt $items.Length; $index++) {
            $items[$index] = ConvertFrom-JsonValue $Value[$index]
        }
        return ,$items
    }
    return $Value
}

function ConvertFrom-InventoryJson {
    param([string]$Json, [int]$Depth = 100)
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return ConvertFrom-Json -InputObject $Json -AsHashtable -Depth $Depth
    }
    return ConvertFrom-JsonValue (ConvertFrom-Json -InputObject $Json)
}

function ConvertTo-InventoryJson {
    param($Value, [int]$Depth = 40)
    $json = ConvertTo-Json -InputObject $Value -Depth $Depth -Compress
    if ($PSVersionTable.PSVersion.Major -le 5 -and $json.Contains('\u')) {
        # Match only JSON escapes, not literal backslash-u text; retain existing PS7 checkpoint hashes.
        $json = [regex]::Replace($json, '(?i)(?<!\\)((?:\\\\)*)\\u(0027|003c|003e|0026)', {
            param($Match)
            $Match.Groups[1].Value + [char][Convert]::ToInt32($Match.Groups[2].Value, 16)
        })
    }
    return $json
}

function ConvertTo-CanonicalValue {
    param($Value)
    if ($Value -is [System.Collections.IDictionary]) {
        $keys = [string[]]@($Value.Keys)
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        $result = [ordered]@{}
        foreach ($key in $keys) { $result[$key] = ConvertTo-CanonicalValue $Value[$key] }
        return $result
    }
    if ($Value -is [System.Collections.IList]) {
        $items = [object[]]::new($Value.Count)
        for ($index = 0; $index -lt $items.Length; $index++) {
            $items[$index] = ConvertTo-CanonicalValue $Value[$index]
        }
        return ,$items
    }
    return $Value
}

function Get-ObjectDigest {
    param($Value)
    return Get-Sha256 (ConvertTo-InventoryJson (ConvertTo-CanonicalValue $Value))
}

function Get-TimestampString {
    param($Value)
    if ($Value -is [DateTimeOffset]) { return $Value.ToUniversalTime().ToString('o') }
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime().ToString('o') }
    return [string]$Value
}

function Get-FileDigest {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Complete-AtomicFile {
    param([string]$Temporary, [string]$Path)
    if ([System.IO.File]::Exists($Path)) {
        [System.IO.File]::Replace($Temporary, $Path, [System.Management.Automation.Language.NullString]::Value)
    }
    else { [System.IO.File]::Move($Temporary, $Path) }
}

function Write-AtomicText {
    param([string]$Path, [string]$Text)
    $temporary = "$Path.pending"
    $stream = [System.IO.FileStream]::new(
        $temporary, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
    )
    try {
        $bytes = $script:Utf8.GetBytes($Text)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
    Complete-AtomicFile $temporary $Path
}

function Write-AtomicJson {
    param([string]$Path, $Value)
    Write-AtomicText $Path (ConvertTo-InventoryJson $Value)
}

function Read-JsonFile {
    param([string]$Path)
    return ConvertFrom-InventoryJson ([System.IO.File]::ReadAllText($Path))
}

function New-InventoryError {
    param([string]$Message, [int]$StatusCode = 0)
    $exception = [System.InvalidOperationException]::new($Message)
    $exception.Data['StatusCode'] = $StatusCode
    return $exception
}

function Assert-Identifier {
    param([string]$Value, [string]$Label)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -match '[\x00-\x1f|]') {
        throw (New-InventoryError "Missing or invalid $Label in an API response.")
    }
}

function Get-ManagedState {
    param($Value)
    if ($Value -is [bool]) {
        if ($Value) { return 'Managed' }
        return 'Unmanaged'
    }
    if ($Value -is [string]) {
        if ($Value -ieq 'true') { return 'Managed' }
        if ($Value -ieq 'false') { return 'Unmanaged' }
    }
    return 'Unknown'
}

function Get-EnvironmentScope {
    param([string]$EnvironmentType, [string]$ManagedState)
    if ($EnvironmentType -ieq 'Developer') {
        if ($ManagedState -eq 'Unmanaged') { return 'Target' }
        if ($ManagedState -eq 'Managed') { return 'Excluded' }
        return 'Review'
    }
    if ($EnvironmentType -in @('Production', 'Default', 'Sandbox', 'Trial', 'Teams', 'Dataverse for Teams')) {
        return 'Excluded'
    }
    if ($ManagedState -eq 'Managed') { return 'Excluded' }
    return 'Review'
}

function Assert-ContinuationUri {
    param([string]$Uri, [string]$InitialUri)
    $candidate = [Uri]::new($Uri, [UriKind]::Absolute)
    $initial = [Uri]::new($InitialUri, [UriKind]::Absolute)
    if ($candidate.Scheme -ne 'https' -or $candidate.Port -ne 443 -or
        $candidate.UserInfo -or $candidate.Fragment -or
        $candidate.Authority -ine $initial.Authority -or
        $candidate.AbsolutePath -cne $initial.AbsolutePath) {
        throw (New-InventoryError 'Rejected a continuation URL outside the original HTTPS endpoint.')
    }
}

function Assert-DataverseUrl {
    param([string]$Url)
    $uri = [Uri]::new($Url, [UriKind]::Absolute)
    if ($uri.Scheme -ne 'https' -or $uri.Port -ne 443 -or $uri.UserInfo -or
        $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/' -or
        $uri.Host -notmatch '^[a-z0-9-]+\.crm[0-9]*\.dynamics\.com$') {
        throw (New-InventoryError 'The environment did not return a supported commercial Dataverse HTTPS URL.')
    }
    return $uri.GetLeftPart([UriPartial]::Authority)
}

function Read-TokenClaims {
    param([string]$Token)
    $parts = $Token.Split('.')
    if ($parts.Length -ne 3) { throw (New-InventoryError 'The access token is not a JWT.') }
    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    $payload = $payload.PadRight($payload.Length + ((4 - $payload.Length % 4) % 4), '=')
    try {
        return ConvertFrom-InventoryJson (
            $script:Utf8.GetString([Convert]::FromBase64String($payload))
        )
    }
    catch { throw (New-InventoryError 'The access token has an invalid claims payload.') }
}

function New-AzTokenProvider {
    param([string]$TenantId, [switch]$UseExistingContext)
    Import-Module Az.Accounts -MinimumVersion 4.0 -ErrorAction Stop
    if ($UseExistingContext) {
        $context = Get-AzContext -ErrorAction Stop
    }
    else {
        Disable-AzContextAutosave -Scope Process | Out-Null
        $login = Connect-AzAccount -Tenant $TenantId -Environment AzureCloud -Scope Process `
            -SkipContextPopulation -ErrorAction Stop
        $context = $login.Context
    }
    if ($null -eq $context -or $context.Tenant.Id -ine $TenantId -or
        $context.Account.Type -ne 'User' -or $context.Environment.Name -ne 'AzureCloud') {
        throw (New-InventoryError 'Select a delegated user context in the requested tenant and AzureCloud. App-only authentication is not supported.')
    }
    $accessTokenCommand = Get-Command Get-AzAccessToken -ErrorAction Stop
    return {
        param([string]$Audience)
        $result = & $accessTokenCommand -TenantId $TenantId -ResourceUrl $Audience `
            -DefaultProfile $context -ErrorAction Stop
        if ($result.Token -is [securestring]) {
            return [System.Net.NetworkCredential]::new('', $result.Token).Password
        }
        return [string]$result.Token
    }.GetNewClosure()
}

function Get-SessionToken {
    param($Session, [string]$Audience, [switch]$Refresh)
    $now = & $Session.Clock
    if (-not $Refresh -and $Session.Tokens.ContainsKey($Audience)) {
        $entry = $Session.Tokens[$Audience]
        if ($entry.Expires -gt $now.AddMinutes(5)) {
            $entry.LastUsed = $now
            return $entry.Token
        }
    }
    $token = & $Session.TokenProvider $Audience
    $claims = Read-TokenClaims $token
    $expires = [DateTimeOffset]::Parse('1970-01-01T00:00:00+00:00').AddSeconds([long](Get-Field $claims 'exp'))
    $audienceClaim = [string](Get-Field $claims 'aud')
    $expectedGuid = if ($Audience -eq $script:ApiRoot) {
        '8578e004-a5c6-46e7-913e-12f58912df43'
    } else { '00000007-0000-0000-c000-000000000000' }
    if ((Get-Field $claims 'tid') -ine $Session.TenantId -or
        [string]::IsNullOrWhiteSpace((Get-Field $claims 'oid')) -or
        [string]::IsNullOrWhiteSpace((Get-Field $claims 'scp')) -or
        (Get-Field $claims 'idtyp') -eq 'app' -or $expires -le $now.AddSeconds(30) -or
        ($Session.PrincipalId -and (Get-Field $claims 'oid') -ine $Session.PrincipalId) -or
        ($audienceClaim.TrimEnd('/') -ine $Audience.TrimEnd('/') -and $audienceClaim -ine $expectedGuid)) {
        throw (New-InventoryError 'Token tenant, delegated identity, audience, or expiry validation failed. Sign in again to the requested tenant.')
    }
    if ($Audience -eq $script:ApiRoot) {
        $hasRole = $false
        foreach ($role in @(Get-Field $claims 'wids')) {
            if ($role -in $script:FullVisibilityRoles) { $hasRole = $true }
        }
        if (-not $hasRole) {
            throw (New-InventoryError 'Full tenant visibility could not be established from the user token wids claim. Activate Global Administrator, Power Platform Administrator, Dynamics 365 Administrator, or Global Reader, then acquire a fresh token. AI-only and environment-scoped roles are insufficient.')
        }
        $Session.PrincipalId = [string]$claims.oid
    }
    if ($Session.Tokens.Count -ge 8 -and -not $Session.Tokens.ContainsKey($Audience)) {
        $oldest = $null
        foreach ($key in $Session.Tokens.Keys) {
            if ($key -ne $script:ApiRoot -and
                ($null -eq $oldest -or $Session.Tokens[$key].LastUsed -lt $Session.Tokens[$oldest].LastUsed)) {
                $oldest = $key
            }
        }
        if ($null -ne $oldest) { $Session.Tokens.Remove($oldest) }
    }
    $Session.Tokens[$Audience] = @{ Token = $token; Expires = $expires; LastUsed = $now }
    return $token
}

function Get-RetryDelayMilliseconds {
    param($Headers, [int]$Attempt, [DateTimeOffset]$Now)
    $delay = -1.0
    foreach ($name in @('x-ms-retry-after-ms', 'retry-after-ms')) {
        $number = 0.0
        if ([double]::TryParse([string](Get-Field $Headers $name),
                [System.Globalization.NumberStyles]::Float,
                [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number) -and
            -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number) -and $number -ge 0) {
            $delay = [Math]::Max($delay, $number)
        }
    }
    $retryAfter = [string](Get-Field $Headers 'Retry-After')
    $seconds = 0.0
    $date = [DateTimeOffset]::MinValue
    if ([double]::TryParse($retryAfter, [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$seconds) -and
        -not [double]::IsNaN($seconds) -and -not [double]::IsInfinity($seconds) -and $seconds -ge 0) {
        $delay = [Math]::Max($delay, $seconds * 1000)
    }
    elseif ([DateTimeOffset]::TryParse($retryAfter, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$date)) {
        $delay = [Math]::Max($delay, [Math]::Max(0, ($date - $Now).TotalMilliseconds))
    }
    if ($delay -ge 0) { return [Math]::Ceiling($delay) }
    return [Math]::Min(60000, 1000 * [Math]::Pow(2, $Attempt)) + (Get-Random -Minimum 0 -Maximum 1001)
}

function Invoke-HttpTransport {
    param($Session, $Request)
    $sensitive = (Get-Field $Request 'Sensitive') -eq $true
    $temporary = if (-not $sensitive) {
        Join-Path ([IO.Path]::GetTempPath()) ('ppi-http-' + [guid]::NewGuid().ToString('N') + '.json')
    } else { '' }
    $parameters = @{
        Uri = $Request.Uri; Method = $Request.Method; Headers = $Request.Headers
        UseBasicParsing = $true; MaximumRedirection = 0
        TimeoutSec = $Session.RequestTimeoutSeconds; ErrorAction = 'Stop'
    }
    if ($temporary) { $parameters.OutFile = $temporary; $parameters.PassThru = $true }
    if ($null -ne $Request.Body) {
        $form = (Get-Field $Request 'ContentType') -eq 'application/x-www-form-urlencoded'
        $parameters.Body = if ($form) { $Request.Body } else { ConvertTo-InventoryJson $Request.Body }
        $parameters.ContentType = if ($form) { 'application/x-www-form-urlencoded' } else { 'application/json' }
    }
    if (-not $Session.ContainsKey('NativeWebRunner') -or $null -eq $Session.NativeWebRunner) {
        $Session.NativeWebRunner = [PowerShell]::Create()
    }
    $runner = $Session.NativeWebRunner
    $runner.Commands.Clear()
    $runner.Streams.Error.Clear()
    # A single reused runspace lets us stop native downloads at the whole-request deadline/size limit.
    $runner.AddScript({
        param($Parameters)
        $ErrorActionPreference = 'Stop'
        $previousTls = [Net.ServicePointManager]::SecurityProtocol
        try {
            if ($PSVersionTable.PSEdition -eq 'Desktop') {
                [Net.ServicePointManager]::SecurityProtocol = $previousTls -bor [Net.SecurityProtocolType]::Tls12
            }
            $response = Invoke-WebRequest @Parameters
            @{
                StatusCode = [int]$response.StatusCode; Headers = $response.Headers
                Body = $(if (-not $Parameters.ContainsKey('OutFile')) { $response.Content } else { '' })
            }
        }
        catch {
            $response = $_.Exception.PSObject.Properties['Response']
            $status = 0; $headers = @{}
            if ($null -ne $response -and $null -ne $response.Value) {
                $status = [int]$response.Value.StatusCode
                $headers = $response.Value.Headers
            }
            @{ StatusCode = $status; Headers = $headers; Body = '' }
        }
        finally { [Net.ServicePointManager]::SecurityProtocol = $previousTls }
    }.ToString(), $true).AddArgument($parameters) | Out-Null
    $operation = $runner.BeginInvoke()
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        while (-not $operation.AsyncWaitHandle.WaitOne(50)) {
            if ($watch.Elapsed.TotalSeconds -ge $Session.RequestTimeoutSeconds) {
                $runner.Stop()
                throw [TimeoutException]::new('Native web request deadline exceeded.')
            }
            if ($temporary -and [IO.File]::Exists($temporary) -and
                ([IO.FileInfo]::new($temporary)).Length -gt 64MB) {
                $runner.Stop()
                throw (New-InventoryError 'API response exceeded the 64 MiB page safety limit. Use a smaller PageSize.')
            }
        }
        $results = $runner.EndInvoke($operation)
        if ($results.Count -ne 1) {
            throw (New-InventoryError 'The native web request returned an invalid result; no empty response fallback was used.')
        }
        $response = $results[0].PSObject.BaseObject
        if ($response.StatusCode -eq 0) {
            throw [Net.WebException]::new('Native web request failed. Check connectivity, TLS, proxy settings, and the endpoint.')
        }
        $headers = @{}
        if ($response.Headers -is [Collections.Specialized.NameValueCollection]) {
            foreach ($name in $response.Headers.AllKeys) { $headers[$name] = $response.Headers[$name] }
        }
        elseif ($response.Headers -is [Collections.IDictionary]) {
            foreach ($name in $response.Headers.Keys) { $headers[$name] = @($response.Headers[$name]) -join ',' }
        }
        else {
            foreach ($header in $response.Headers) { $headers[$header.Key] = @($header.Value) -join ',' }
        }
        $text = ''
        if ($temporary -and [IO.File]::Exists($temporary)) {
            if (([IO.FileInfo]::new($temporary)).Length -gt 64MB) {
                throw (New-InventoryError 'API response exceeded the 64 MiB page safety limit. Use a smaller PageSize.')
            }
            $text = [IO.File]::ReadAllText($temporary, $script:Utf8)
        }
        elseif ($sensitive) {
            $text = if ($response.Body -is [byte[]]) { $script:Utf8.GetString($response.Body) } else { [string]$response.Body }
            if ($script:Utf8.GetByteCount($text) -gt 1MB) {
                throw (New-InventoryError 'The authentication response exceeded its safety limit.')
            }
        }
        return @{ StatusCode = [int]$response.StatusCode; Headers = $headers; Body = $text }
    }
    finally {
        $runner.Commands.Clear()
        $parameters.Clear()
        $runner.Streams.Error.Clear()
        $operation.AsyncWaitHandle.Dispose()
        if ($temporary -and [IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Invoke-InventoryRequest {
    param($Session, $Spec, [string]$Uri, $Body)
    Assert-ContinuationUri $Uri $Spec.Uri
    $started = & $Session.Clock
    $refreshed = $false
    $retry = 0
    while ($true) {
        $wait = ($Session.NotBefore - (& $Session.Clock)).TotalMilliseconds
        if ($wait -gt 0) { & $Session.Sleep ([Math]::Ceiling($wait)) }
        if ($retry -gt 0 -and ((& $Session.Clock) - $started).TotalSeconds -ge $Session.RetryBudgetSeconds) {
            $Session.Halt = $true
            throw (New-InventoryError "Retry time budget exhausted for $($Spec.Kind). Resume later.")
        }
        try { $token = Get-SessionToken $Session $Spec.Audience }
        catch [System.InvalidOperationException] {
            $Session.Halt = $true
            throw
        }
        $request = @{
            Method = $Spec.Method; Uri = $Uri; Body = $Body
            Headers = @{
                Authorization = "Bearer $token"; Accept = 'application/json'
                Prefer = "odata.maxpagesize=$($Session.PageSize)"
                'OData-MaxVersion' = '4.0'; 'OData-Version' = '4.0'
            }
        }
        $networkFailure = $false
        try {
            $Session.Requests++
            if ($null -ne $Session.Transport) { $response = & $Session.Transport $request }
            else { $response = Invoke-HttpTransport $Session $request }
            $status = [int]$response.StatusCode
        }
        catch [System.Net.WebException], [System.OperationCanceledException],
              [System.TimeoutException], [System.IO.IOException] {
            $networkFailure = $true
            $status = 0
            $response = @{ Headers = @{} }
        }
        $now = & $Session.Clock
        $Session.NotBefore = $now.AddMilliseconds($Session.RequestIntervalMilliseconds)
        if (-not $networkFailure -and $status -ge 200 -and $status -lt 300) {
            if ($response.Body -is [string]) {
                try { return ConvertFrom-InventoryJson $response.Body }
                catch { throw (New-InventoryError "Invalid JSON response from $($Spec.Kind)." $status) }
            }
            return $response.Body
        }
        if ($status -eq 401 -and -not $refreshed) {
            try { Get-SessionToken $Session $Spec.Audience -Refresh | Out-Null }
            catch [System.InvalidOperationException] {
                $Session.Halt = $true
                throw
            }
            $refreshed = $true
            continue
        }
        $transient = $networkFailure -or $status -in @(408, 429) -or
            ($status -ge 500 -and $status -le 599 -and $status -notin @(501, 505))
        if (-not $transient) {
            throw (New-InventoryError "HTTP $status from $($Spec.Kind). Check delegated permissions and environment access; no user-scoped fallback was used." $status)
        }
        $delay = Get-RetryDelayMilliseconds $response.Headers $retry $now
        $remaining = $Session.RetryBudgetSeconds * 1000 - ($now - $started).TotalMilliseconds
        if ($delay -gt $remaining) {
            $Session.Halt = $true
            throw (New-InventoryError "Retry budget exhausted for $($Spec.Kind); required backoff was not shortened. Resume later." $status)
        }
        $Session.NotBefore = $now.AddMilliseconds([Math]::Max($delay, $Session.RequestIntervalMilliseconds))
        if ($retry -ge $Session.MaxRetries) {
            throw (New-InventoryError "Retry attempts exhausted for $($Spec.Kind) (HTTP $status; 0 means a network failure)." $status)
        }
        Write-Warning "$($Spec.Kind): transient HTTP $status; waiting $delay ms before retry $($retry + 1)."
        $retry++
    }
}

function New-InventoryQuery {
    param([string]$TenantId, [switch]$Environments)
    $environmentProjection = @(
        'joinKey = tolower(name)', 'environmentName = properties.displayName',
        'environmentType = properties.environmentType', 'isManagedEnvironment = properties.isManaged'
    )
    $clauses = [System.Collections.Generic.List[object]]::new()
    $clauses.Add(@{ '$type' = 'where'; FieldName = 'tenantId'; Operator = '=='; Values = @("'$TenantId'") })
    if ($Environments) {
        $clauses.Add(@{
            '$type' = 'where'; FieldName = 'type'; Operator = '=='
            Values = @("'microsoft.powerplatform/environments'")
        })
    }
    else {
        $clauses.Add(@{
            '$type' = 'where'; FieldName = 'type'; Operator = 'startswith'
            Values = @("'microsoft.powerapps/'")
        })
        $clauses.Add(@{
            '$type' = 'extend'; FieldName = 'joinKey'
            Expression = 'tolower(tostring(properties.environmentId))'
        })
        $clauses.Add(@{
            '$type' = 'join'; JoinKind = 'leftouter'
            LeftColumnName = 'joinKey'; RightColumnName = 'joinKey'
            RightTable = @{
                TableName = 'PowerPlatformResources'
                Clauses = @(
                    @{ '$type' = 'where'; FieldName = 'tenantId'; Operator = '=='; Values = @("'$TenantId'") },
                    @{ '$type' = 'where'; FieldName = 'type'; Operator = '=='; Values = @("'microsoft.powerplatform/environments'") },
                    @{ '$type' = 'project'; FieldList = $environmentProjection }
                )
            }
        })
    }
    $clauses.Add(@{ '$type' = 'orderby'; FieldNamesAscDesc = @{ id = 'asc' } })
    return @{ TableName = 'PowerPlatformResources'; Clauses = $clauses.ToArray() }
}

function New-SourceSpec {
    param([string]$Kind, [string]$TenantId, $Environment, [string]$DataverseUrl, [int]$PageSize = 1000)
    $environmentId = if ($null -ne $Environment) { $Environment.EnvironmentId } else { '' }
    $spec = [ordered]@{
        Kind = $Kind; EnvironmentId = $environmentId; Environment = $Environment
        Method = 'GET'; Uri = ''; Audience = $script:ApiRoot; Query = $null
    }
    $encoded = [Uri]::EscapeDataString($environmentId)
    switch ($Kind) {
        { $_ -in @('InventoryEnvironments', 'InventoryApps') } {
            $spec.Method = 'POST'
            $spec.Uri = "$script:ApiRoot/resourcequery/resources/query?api-version=$script:ApiVersion"
            $spec.Query = New-InventoryQuery $TenantId -Environments:($Kind -eq 'InventoryEnvironments')
        }
        'AdminApps' {
            $spec.Uri = "$script:ApiRoot/powerapps/environments/$encoded/apps?api-version=$script:ApiVersion&`$top=$PageSize"
        }
        'EnvironmentDetail' {
            $spec.Uri = "$script:ApiRoot/environmentmanagement/environments/$encoded`?api-version=$script:ApiVersion"
        }
        { $_ -in @('DataversePublished', 'DataverseUnpublished') } {
            $spec.Audience = Assert-DataverseUrl $DataverseUrl
            $suffix = if ($Kind -eq 'DataverseUnpublished') {
                '/Microsoft.Dynamics.CRM.RetrieveUnpublishedMultiple()'
            } else { '' }
            $spec.Uri = $spec.Audience + '/api/data/v9.2/appmodules' + $suffix +
                '?$select=appmoduleid,name,uniquename,createdon,modifiedon,componentstate&$filter=componentstate%20lt%202&$orderby=appmoduleid'
        }
        default { throw (New-InventoryError "Unsupported source kind: $Kind") }
    }
    return $spec
}

function Get-SourceId {
    param($Spec)
    return Get-Sha256 ($Spec.Kind + '|' + $Spec.EnvironmentId.ToLowerInvariant())
}

function Get-PagePath {
    param([string]$Directory, [long]$Number)
    return Join-Path $Directory ('page-{0:D10}.ndjson' -f $Number)
}

function Assert-SourceIntegrity {
    param([string]$Directory, $State)
    if ($State.PageCount -lt 0 -or $State.RowCount -lt 0 -or
        $State.SpecHash -ne (Get-ObjectDigest $State.Spec) -or
        [System.IO.Path]::GetFileName($Directory) -ne (Get-SourceId $State.Spec)) {
        throw (New-InventoryError 'Source checkpoint identity or counters are corrupt.')
    }
    $head = ''
    $rows = 0L
    $last = $null
    for ($number = 1L; $number -le $State.PageCount; $number++) {
        $path = Get-PagePath $Directory $number
        $metadataPath = "$path.json"
        $metadata = Read-JsonFile $metadataPath
        if ($metadata.Number -ne $number -or $metadata.PreviousHash -ne $head -or
            $metadata.DataHash -ne (Get-FileDigest $path)) {
            throw (New-InventoryError "Committed page integrity check failed: $path")
        }
        $cursorMarker = Join-Path $Directory ('cursor-' + $metadata.CursorHash)
        if ([System.IO.File]::ReadAllText($cursorMarker) -ne [string]$number) {
            throw (New-InventoryError 'A committed cursor marker does not match its page.')
        }
        if ($metadata.Count -gt 0) {
            $contentMarker = Join-Path $Directory ('content-' + $metadata.DataHash)
            if ([System.IO.File]::ReadAllText($contentMarker) -ne [string]$number) {
                throw (New-InventoryError 'A committed content marker does not match its page.')
            }
        }
        $head = Get-FileDigest $metadataPath
        $rows += $metadata.Count
        $last = $metadata
    }
    if ($head -ne $State.HeadHash -or $rows -ne $State.RowCount) {
        throw (New-InventoryError 'Source checkpoint and committed pages do not agree.')
    }
    if ($null -ne $last) {
        if ($last.NextCursor -cne $State.Cursor -or $last.LastId -cne $State.LastId -or
            $State.Complete -ne (-not [bool]$last.NextCursor)) {
            throw (New-InventoryError 'The source cursor or completion flag does not match its committed page.')
        }
    }
    elseif ($State.Cursor -or $State.LastId -or $State.Complete) {
        throw (New-InventoryError 'An empty source has an invalid cursor or completion flag.')
    }
}

function Get-SourceStates {
    param([string]$Root)
    $directory = Join-Path $Root '.sources'
    if ([System.IO.Directory]::Exists($directory)) {
        foreach ($path in [System.IO.Directory]::EnumerateFiles($directory, 'state.json', [System.IO.SearchOption]::AllDirectories)) {
            [pscustomobject]@{ Directory = [System.IO.Path]::GetDirectoryName($path); State = Read-JsonFile $path }
        }
    }
}

function Read-StagedRows {
    param([string]$Directory, $State)
    for ($number = 1L; $number -le $State.PageCount; $number++) {
        $reader = [System.IO.StreamReader]::new((Get-PagePath $Directory $number), $script:Utf8)
        try {
            while ($null -ne ($line = $reader.ReadLine())) {
                $separator = $line.IndexOf("`t")
                if ($separator -lt 1) { throw (New-InventoryError 'Invalid staged record format.') }
                ConvertFrom-InventoryJson $line.Substring($separator + 1) -Depth 40
            }
        }
        finally { $reader.Dispose() }
    }
}

function Get-TruncationFlag {
    param($Value)
    if ($Value -is [bool]) { return $Value }
    if ([string]$Value -ieq 'true') { return $true }
    if ([string]$Value -ieq 'false') { return $false }
    # ResourceQueryResponse uses the ARG enum: 0 = truncated, 1 = not truncated.
    if ($null -ne $Value -and [string]$Value -eq '0') { return $true }
    if ($null -ne $Value -and [string]$Value -eq '1') { return $false }
    throw (New-InventoryError 'Missing or unrecognized Inventory resultTruncated value.')
}

function Invoke-Source {
    param($Session, $Spec)
    $directory = Join-Path (Join-Path $Session.Root '.sources') (Get-SourceId $Spec)
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $statePath = Join-Path $directory 'state.json'
    $specHash = Get-ObjectDigest $Spec
    if ([System.IO.File]::Exists($statePath)) {
        $state = Read-JsonFile $statePath
        if ($state.SpecHash -ne $specHash) {
            throw (New-InventoryError 'A source definition changed. Use a new output directory for a fresh scan.')
        }
        if ($state.Complete) { return @{ Directory = $directory; State = $state } }
    }
    else {
        $state = [ordered]@{
            Spec = $Spec; SpecHash = $specHash; PageCount = 0L; RowCount = 0L
            Cursor = ''; HeadHash = ''; LastId = ''; Complete = $false
            FirstTotal = $null; LastTotal = $null; DriftDetected = $false; Failure = $null
        }
        Write-AtomicJson $statePath $state
    }
    try {
        while (-not $state.Complete) {
            $cursor = [string]$state.Cursor
            $uri = $Spec.Uri
            $body = $null
            $inventory = $Spec.Kind -in @('InventoryEnvironments', 'InventoryApps')
            if ($inventory) {
                $body = @{
                    TableName = $Spec.Query.TableName; Clauses = $Spec.Query.Clauses
                    Options = @{ Top = $Session.PageSize }
                }
                if ($cursor) { $body.Options.SkipToken = $cursor }
            }
            elseif ($cursor) { $uri = $cursor }
            $response = Invoke-InventoryRequest $Session $Spec $uri $body
            $next = ''
            $total = $null
            if ($Spec.Kind -eq 'EnvironmentDetail') { $data = @($response) }
            else {
                $field = if ($inventory) { 'data' } else { 'value' }
                $data = Get-Field $response $field
                if ($data -isnot [System.Collections.IList]) {
                    throw (New-InventoryError "Missing array '$field' in $($Spec.Kind) response.")
                }
            }
            if ($data.Count -gt $Session.PageSize) {
                throw (New-InventoryError "$($Spec.Kind) exceeded the requested page size.")
            }
            if ($inventory) {
                $count = 0L; $parsedTotal = 0L
                if (-not [long]::TryParse([string](Get-Field $response 'count'), [ref]$count) -or
                    -not [long]::TryParse([string](Get-Field $response 'totalRecords'), [ref]$parsedTotal) -or
                    $count -ne $data.Count -or $parsedTotal -lt 0) {
                    throw (New-InventoryError 'Inventory count/totalRecords did not match the page contract.')
                }
                $total = $parsedTotal
                $next = [string](Get-Field $response 'skipToken')
                $truncated = Get-TruncationFlag (Get-Field $response 'resultTruncated')
                if (-not $next -and ($truncated -or $state.RowCount + $count -lt $total)) {
                    throw (New-InventoryError 'Inventory results are truncated or incomplete but no continuation token was returned.')
                }
            }
            elseif ($Spec.Kind -ne 'EnvironmentDetail') {
                $next = [string](Get-Field $response 'nextLink')
                if (-not $next) { $next = [string](Get-Field $response '@odata.nextLink') }
                if ($next) { Assert-ContinuationUri $next $Spec.Uri }
            }
            if ($next -and ($next -ceq $cursor -or $data.Count -eq 0)) {
                throw (New-InventoryError 'Repeated continuation token or empty nonterminal page.')
            }
            if ($next) {
                $seen = Join-Path $directory ('cursor-' + (Get-Sha256 $next))
                if ([System.IO.File]::Exists($seen) -and
                    [long][System.IO.File]::ReadAllText($seen) -le $state.PageCount) {
                    throw (New-InventoryError 'A continuation token cycled to an already committed page.')
                }
            }
            $lines = [System.Collections.Generic.List[string]]::new($data.Count)
            $lastId = [string]$state.LastId
            foreach ($row in $data) {
                if ($inventory) {
                    $id = [string](Get-Field $row 'id')
                    Assert-Identifier $id 'Inventory resource id'
                    if ($lastId -and [string]::CompareOrdinal($id, $lastId) -le 0) {
                        throw (New-InventoryError 'Inventory resource IDs were repeated or not strictly ordered across pages.')
                    }
                    $lastId = $id
                }
                $record = ConvertTo-InventoryRecord $row $Spec $Session.TenantId
                $lines.Add($record.Key + "`t" + (ConvertTo-InventoryJson $record -Depth 20))
            }
            $lines.Sort([StringComparer]::Ordinal)
            $number = $state.PageCount + 1L
            $path = Get-PagePath $directory $number
            $writer = [System.IO.StreamWriter]::new("$path.pending", $false, $script:Utf8)
            try {
                foreach ($line in $lines) { $writer.WriteLine($line) }
                $writer.Flush()
                $writer.BaseStream.Flush($true)
            }
            finally { $writer.Dispose() }
            Complete-AtomicFile "$path.pending" $path
            $digest = Get-FileDigest $path
            $contentMarker = Join-Path $directory ('content-' + $digest)
            if ($data.Count -gt 0 -and [System.IO.File]::Exists($contentMarker) -and
                [long][System.IO.File]::ReadAllText($contentMarker) -le $state.PageCount) {
                throw (New-InventoryError 'The service repeated a committed page under a different continuation token.')
            }
            $metadata = [ordered]@{
                Number = $number; Count = $data.Count; DataHash = $digest
                PreviousHash = $state.HeadHash; CursorHash = Get-Sha256 $cursor
                NextCursor = $next; LastId = $lastId
            }
            Write-AtomicJson "$path.json" $metadata
            if ($null -ne $Session.FaultHook) { & $Session.FaultHook 'BeforeCheckpoint' $Spec $number }
            Write-AtomicText (Join-Path $directory ('cursor-' + (Get-Sha256 $cursor))) ([string]$number)
            if ($data.Count -gt 0) { Write-AtomicText $contentMarker ([string]$number) }
            $state.PageCount = $number
            $state.RowCount += $data.Count
            $state.Cursor = $next
            $state.LastId = $lastId
            $state.HeadHash = Get-FileDigest "$path.json"
            $state.Failure = $null
            $state.Complete = -not [bool]$next
            if ($null -ne $total) {
                if ($null -eq $state.FirstTotal) { $state.FirstTotal = $total }
                if ($state.FirstTotal -ne $total -or ($state.Complete -and $state.RowCount -ne $total)) {
                    $state.DriftDetected = $true
                }
                $state.LastTotal = $total
            }
            Write-AtomicJson $statePath $state
            if ($null -ne $Session.FaultHook) { & $Session.FaultHook 'AfterCheckpoint' $Spec $number }
        }
    }
    catch [System.InvalidOperationException] {
        $state.Failure = @{
            Message = $_.Exception.Message; StatusCode = [int]$_.Exception.Data['StatusCode']
            Utc = (& $Session.Clock).ToString('o')
        }
        Write-AtomicJson $statePath $state
        Write-Warning "$($Spec.Kind) [$($Spec.EnvironmentId)]: $($state.Failure.Message)"
    }
    return @{ Directory = $directory; State = $state }
}

function Merge-RunFiles {
    param([string[]]$Paths, [string]$Destination)
    $readers = [System.Collections.Generic.List[System.IO.StreamReader]]::new()
    $queue = [System.Collections.Generic.SortedList[string,System.Collections.Generic.Queue[int]]]::new([StringComparer]::Ordinal)
    $writer = [System.IO.StreamWriter]::new($Destination, $false, $script:Utf8)
    try {
        for ($index = 0; $index -lt $Paths.Count; $index++) {
            $reader = [System.IO.StreamReader]::new($Paths[$index], $script:Utf8)
            $readers.Add($reader)
            $line = $reader.ReadLine()
            if ($null -ne $line) {
                if (-not $queue.ContainsKey($line)) { $queue.Add($line, [System.Collections.Generic.Queue[int]]::new()) }
                $queue[$line].Enqueue($index)
            }
        }
        while ($queue.Count -gt 0) {
            $line = $queue.Keys[0]
            $index = $queue.Values[0].Dequeue()
            if ($queue.Values[0].Count -eq 0) { $queue.RemoveAt(0) }
            $writer.WriteLine($line)
            $line = $readers[$index].ReadLine()
            if ($null -ne $line) {
                if (-not $queue.ContainsKey($line)) { $queue.Add($line, [System.Collections.Generic.Queue[int]]::new()) }
                $queue[$line].Enqueue($index)
            }
        }
    }
    finally {
        $writer.Dispose()
        foreach ($reader in $readers) { $reader.Dispose() }
    }
}

function New-MergedJournal {
    param([string]$Root)
    $directory = Join-Path $Root '.merge'
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $list = Join-Path $directory 'inputs.txt'
    $writer = [System.IO.StreamWriter]::new($list, $false, $script:Utf8)
    try {
        Get-SourceStates $Root | ForEach-Object {
            for ($number = 1L; $number -le $_.State.PageCount; $number++) {
                $writer.WriteLine((Get-PagePath $_.Directory $number))
            }
        }
    }
    finally { $writer.Dispose() }
    $pass = 0
    while ($true) {
        $nextList = Join-Path $directory "pass-$pass.txt"
        $reader = [System.IO.StreamReader]::new($list, $script:Utf8)
        $writer = [System.IO.StreamWriter]::new($nextList, $false, $script:Utf8)
        $batch = [System.Collections.Generic.List[string]]::new(32)
        $runs = 0
        try {
            while ($null -ne ($line = $reader.ReadLine())) {
                $batch.Add($line)
                if ($batch.Count -eq 32) {
                    $destination = Join-Path $directory "pass-$pass-run-$runs.ndjson"
                    Merge-RunFiles $batch.ToArray() $destination
                    $writer.WriteLine($destination)
                    $runs++
                    $batch.Clear()
                }
            }
            if ($batch.Count -gt 0 -or $runs -eq 0) {
                $destination = Join-Path $directory "pass-$pass-run-$runs.ndjson"
                Merge-RunFiles $batch.ToArray() $destination
                $writer.WriteLine($destination)
                $runs++
            }
        }
        finally { $reader.Dispose(); $writer.Dispose() }
        if ($runs -eq 1) {
            return [System.IO.File]::ReadAllText($nextList).TrimEnd("`r", "`n")
        }
        $list = $nextList
        $pass++
    }
}

function Write-CsvLine {
    param([System.IO.StreamWriter]$Writer, [string[]]$Columns, $Row)
    $cells = [string[]]::new($Columns.Length)
    for ($index = 0; $index -lt $Columns.Length; $index++) {
        $value = Get-TimestampString (Get-Field $Row $Columns[$index])
        if ($value -match '^[\s]*[=+@-]' -or $value -match '^[\t\r\n]') { $value = "'" + $value }
        $cells[$index] = '"' + $value.Replace('"', '""') + '"'
    }
    $Writer.WriteLine([string]::Join(',', $cells))
}

function New-CsvWriter {
    param([string]$Path, [string[]]$Columns)
    $writer = [System.IO.StreamWriter]::new("$Path.pending", $false, $script:Utf8)
    $header = @{}
    foreach ($column in $Columns) { $header[$column] = $column }
    Write-CsvLine $writer $Columns $header
    return $writer
}

function Merge-AppRecord {
    param($Current, $Incoming)
    if ($null -eq $Current) {
        $Incoming.Sources = $Incoming.Source
        $Incoming.MetadataConflict = $false
        $Incoming.DuplicateSourceRecord = $false
        $Incoming.OwnerMetadataSource = if ($Incoming.OwnerObjectId -or $Incoming.OwnerName -or $Incoming.OwnerEmail) {
            $Incoming.Source
        } else { '' }
        return $Incoming
    }
    foreach ($field in @('EnvironmentType', 'ManagedState', 'Scope', 'AppType')) {
        if ($Current[$field] -and $Incoming[$field] -and $Current[$field] -ine $Incoming[$field]) {
            $Current.MetadataConflict = $true
        }
    }
    foreach ($field in @(
        'AppName', 'AppType', 'AppSubType', 'ResourceId', 'CreatorObjectId',
        'CreatedUtc', 'ModifiedUtc', 'EnvironmentName'
    )) {
        if (-not $Current[$field] -and $Incoming[$field]) { $Current[$field] = $Incoming[$field] }
    }
    if (($Incoming.OwnerObjectId -or $Incoming.OwnerName -or $Incoming.OwnerEmail) -and
        (-not $Current.OwnerMetadataSource -or $Incoming.Source -eq 'AdminApps')) {
        foreach ($field in @('OwnerObjectId', 'OwnerName', 'OwnerEmail')) {
            $Current[$field] = $Incoming[$field]
        }
        $Current.OwnerMetadataSource = $Incoming.Source
    }
    if ($Incoming.PremiumClassification -eq 'Premium') {
        $Current.PremiumClassification = 'Premium'
        $Current.PremiumEvidence = $Incoming.PremiumEvidence
    }
    if ($Incoming.PublicationState -eq 'Unpublished' -or -not $Current.PublicationState) {
        $Current.PublicationState = $Incoming.PublicationState
    }
    if ($Incoming.Source -notin $Current.Sources.Split(';')) {
        $Current.Sources += ';' + $Incoming.Source
    }
    else { $Current.DuplicateSourceRecord = $true }
    return $Current
}

function Write-AppReportRow {
    param($Row, $Writers, [string[]]$Columns, $Summary, [string]$TenantId)
    $Summary.UniqueAppsObserved++
    if ($Row.MetadataConflict) {
        $Row.Scope = 'Review'
        $Row.PremiumEvidence += ' Conflicting source metadata; review environment scope and app type.'
    }
    if ($Row.DuplicateSourceRecord) {
        $Row.Scope = 'Review'
        $Row.PremiumEvidence += ' The same source repeated this app ID; review pagination and data churn.'
    }
    if ($Row.Scope -eq 'Excluded') { $Summary.ExcludedApps++; return }
    $Row.TenantId = $TenantId
    $Row.ObservedFromUtc = $Summary.StartedUtc
    $Row.OwnerStatus = if ($Row.AppType -ieq 'microsoft.powerapps/modeldrivenapps') {
        $Row.OwnerObjectId = ''; $Row.OwnerName = ''; $Row.OwnerEmail = ''
        'NotApplicable'
    } elseif ($Row.OwnerObjectId) { 'Reported' } else { 'Unknown' }
    if (-not $Row.AppType) { $Row.AppType = 'UnknownAdminApp' }
    $Row.EnvironmentLink = if ($Row.EnvironmentId) {
        'https://admin.powerplatform.microsoft.com/environments/environment/' +
            [Uri]::EscapeDataString($Row.EnvironmentId) + '/hub'
    } else { '' }
    $Row.AppLink = if ($Row.EnvironmentId) {
        'https://make.powerapps.com/environments/' + [Uri]::EscapeDataString($Row.EnvironmentId) + '/apps'
    } else { '' }
    Write-CsvLine $Writers['AllApps.csv'] $Columns $Row
    $Summary.ReportedApps++
    if ($Row.Scope -eq 'Target' -and $Row.PremiumClassification -eq 'Premium') {
        Write-CsvLine $Writers['PremiumApps.csv'] $Columns $Row
        $Summary.PremiumApps++
    }
    if ($Row.Scope -ne 'Target' -or $Row.PremiumClassification -eq 'Unknown' -or
        $Row.AppType -notin @(
            'microsoft.powerapps/canvasapps', 'microsoft.powerapps/modeldrivenapps',
            'microsoft.powerapps/codeapps', 'microsoft.powerapps/apps'
        )) {
        Write-CsvLine $Writers['ReviewApps.csv'] $Columns $Row
        $Summary.ReviewApps++
    }
}

function Export-InventoryReports {
    param($Session, $Checkpoint)
    $appColumns = @(
        'TenantId', 'AppId', 'AppName', 'AppType', 'AppSubType', 'OwnerObjectId', 'OwnerName',
        'OwnerEmail', 'OwnerStatus', 'CreatorObjectId', 'EnvironmentId', 'EnvironmentName',
        'EnvironmentType', 'ManagedState', 'Scope', 'PremiumClassification', 'PremiumEvidence',
        'PublicationState', 'Location', 'CreatedUtc', 'ModifiedUtc', 'ObservedFromUtc',
        'Sources', 'ResourceId', 'AppLink', 'EnvironmentLink'
    )
    $environmentColumns = @(
        'TenantId', 'EnvironmentId', 'EnvironmentName', 'EnvironmentType', 'ManagedState', 'Scope', 'Location'
    )
    $coverageColumns = @(
        'Source', 'EnvironmentId', 'Status', 'Pages', 'Records', 'FirstTotal', 'LastTotal', 'Message'
    )
    $failureColumns = @('Source', 'EnvironmentId', 'StatusCode', 'Message', 'Utc')
    $summary = [ordered]@{
        FormatVersion = $script:FormatVersion; RunId = $Checkpoint.RunId
        TenantId = $Session.TenantId; Cloud = 'Commercial'; PrincipalObjectId = $Session.PrincipalId
        AuthenticationMode = $Session.AuthenticationMode
        StartedUtc = Get-TimestampString $Checkpoint.StartedUtc
        GeneratedUtc = (& $Session.Clock).ToString('o')
        Status = 'Incomplete'; ExitCode = 1; ReportsCurrent = $false
        UniqueAppsObserved = 0L; ExcludedApps = 0L; ReportedApps = 0L
        PremiumApps = 0L; ReviewApps = 0L; Environments = 0L; TargetEnvironments = 0L
        ReviewEnvironments = 0L; Sources = 0L; IncompleteSources = 0L; UnstableSources = 0L
        RequestsThisInvocation = $Session.Requests; ReportHashes = @{}
        DiscoveryScope = 'All documented app inventory types, admin app listings, and published/unpublished Dataverse app modules. Eventually consistent, not a transactional snapshot.'
        ClassificationScope = 'Positive premium capability evidence, not a per-user license entitlement audit. Standard or absent connector metadata never proves nonpremium; called flows require review.'
    }
    $writers = @{}
    $merged = New-MergedJournal $Session.Root
    try {
        foreach ($name in @('AllApps.csv', 'PremiumApps.csv', 'ReviewApps.csv')) {
            $writers[$name] = New-CsvWriter (Join-Path $Session.Root $name) $appColumns
        }
        $writers['Environments.csv'] = New-CsvWriter (Join-Path $Session.Root 'Environments.csv') $environmentColumns
        $writers['Coverage.csv'] = New-CsvWriter (Join-Path $Session.Root 'Coverage.csv') $coverageColumns
        $writers['Failures.csv'] = New-CsvWriter (Join-Path $Session.Root 'Failures.csv') $failureColumns
        $reader = [System.IO.StreamReader]::new($merged, $script:Utf8)
        $current = $null
        $activeEnvironment = $null
        try {
            while ($null -ne ($line = $reader.ReadLine())) {
                $separator = $line.IndexOf("`t")
                $record = ConvertFrom-InventoryJson $line.Substring($separator + 1) -Depth 40
                if ($record.RowKind -eq 'App') {
                    if ($null -eq $activeEnvironment -or
                        $activeEnvironment.EnvironmentId -ine $record.EnvironmentId) {
                        $record.Scope = 'Review'
                    }
                    else {
                        foreach ($field in @('EnvironmentType', 'ManagedState', 'Scope')) {
                            if ($activeEnvironment[$field] -ine $record[$field]) {
                                $record.Scope = 'Review'
                                $record.PremiumEvidence += ' Environment metadata changed or differs between inventory queries.'
                                break
                            }
                        }
                    }
                    if ($null -ne $current -and $record.Key -cne $current.Key) {
                        Write-AppReportRow $current $writers $appColumns $summary $Session.TenantId
                        $current = $null
                    }
                    $current = Merge-AppRecord $current $record
                }
                else {
                    if ($null -ne $current) {
                        Write-AppReportRow $current $writers $appColumns $summary $Session.TenantId
                        $current = $null
                    }
                }
                if ($record.RowKind -eq 'Environment') {
                    $activeEnvironment = $record
                    $record.TenantId = $Session.TenantId
                    Write-CsvLine $writers['Environments.csv'] $environmentColumns $record
                    $summary.Environments++
                    if ($record.Scope -eq 'Target') { $summary.TargetEnvironments++ }
                    if ($record.Scope -eq 'Review') { $summary.ReviewEnvironments++ }
                }
            }
            if ($null -ne $current) {
                Write-AppReportRow $current $writers $appColumns $summary $Session.TenantId
            }
        }
        finally { $reader.Dispose() }
        Get-SourceStates $Session.Root | ForEach-Object {
            $state = $_.State
            $summary.Sources++
            $message = ''
            $status = 'Complete'
            if (-not $state.Complete) {
                $summary.IncompleteSources++
                $status = 'Incomplete'
                $message = 'Source did not reach its terminal page.'
            }
            if ($state.DriftDetected) {
                $summary.UnstableSources++
                $status = 'ChangedDuringScan'
                $message = 'Inventory totals changed while paging. Use a new output directory to refresh the scan.'
            }
            if ($null -ne $state.Failure) {
                $message = $state.Failure.Message
                Write-CsvLine $writers['Failures.csv'] $failureColumns @{
                    Source = $state.Spec.Kind; EnvironmentId = $state.Spec.EnvironmentId
                    StatusCode = $state.Failure.StatusCode; Message = $message; Utc = $state.Failure.Utc
                }
            }
            Write-CsvLine $writers['Coverage.csv'] $coverageColumns @{
                Source = $state.Spec.Kind; EnvironmentId = $state.Spec.EnvironmentId; Status = $status
                Pages = $state.PageCount; Records = $state.RowCount
                FirstTotal = $state.FirstTotal; LastTotal = $state.LastTotal; Message = $message
            }
        }
        foreach ($writer in $writers.Values) {
            $writer.Flush()
            $writer.BaseStream.Flush($true)
        }
    }
    finally { foreach ($writer in $writers.Values) { $writer.Dispose() } }
    foreach ($name in $writers.Keys) {
        $path = Join-Path $Session.Root $name
        Complete-AtomicFile "$path.pending" $path
        $summary.ReportHashes[$name] = Get-FileDigest $path
    }
    if ($summary.IncompleteSources -eq 0 -and -not $Session.Halt) {
        if ($summary.ReviewApps -gt 0 -or $summary.ReviewEnvironments -gt 0 -or $summary.UnstableSources -gt 0) {
            $summary.Status = 'NeedsReview'; $summary.ExitCode = 2
        }
        else { $summary.Status = 'Complete'; $summary.ExitCode = 0 }
    }
    $summary.ReportsCurrent = $true
    Write-AtomicJson (Join-Path $Session.Root 'RunSummary.json') $summary
    $mergeDirectory = Join-Path $Session.Root '.merge'
    foreach ($path in [System.IO.Directory]::EnumerateFiles($mergeDirectory)) {
        [System.IO.File]::Delete($path)
    }
    [System.IO.Directory]::Delete($mergeDirectory)
    return [pscustomobject]$summary
}

function Invoke-DeveloperPremiumInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][guid]$TenantId,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [ValidateRange(1, 1000)][int]$PageSize = 1000,
        [ValidateRange(0, 60000)][int]$RequestIntervalMilliseconds = 1000,
        [ValidateRange(0, 12)][int]$MaxRetries = 8,
        [ValidateRange(1, 86400)][int]$RetryBudgetSeconds = 900,
        [ValidateRange(1, 600)][int]$RequestTimeoutSeconds = 120,
        [switch]$Resume,
        [switch]$UseExistingContext,
        [ValidateSet('Auto', 'AzAccounts', 'ClientSecret', 'Certificate')][string]$AuthenticationMode = 'Auto',
        [guid]$ClientId,
        [securestring]$ClientSecret,
        [Security.Cryptography.X509Certificates.X509Certificate2]$ClientCertificate,
        [string]$RedirectUri = 'http://localhost:8400/',
        [ValidateRange(30, 1800)][int]$LoginTimeoutSeconds = 600,
        [scriptblock]$TokenProvider,
        [scriptblock]$Transport,
        [scriptblock]$Sleep = { param($Milliseconds) Start-Sleep -Milliseconds ([long]$Milliseconds) },
        [scriptblock]$Clock = { [DateTimeOffset]::UtcNow },
        [scriptblock]$FaultHook,
        [scriptblock]$AuthCodeReceiver,
        [scriptblock]$AuthTokenRequest
    )
    $tenant = $TenantId.ToString()
    if ($null -ne $ClientSecret -and $null -ne $ClientCertificate) {
        throw (New-InventoryError 'Choose a client secret or a certificate, not both.')
    }
    if ($AuthenticationMode -eq 'Auto') {
        $AuthenticationMode = if ($null -ne $ClientCertificate) { 'Certificate' }
            elseif ($ClientId -ne [guid]::Empty -or $null -ne $ClientSecret) { 'ClientSecret' }
            else { 'AzAccounts' }
    }
    if ($AuthenticationMode -eq 'AzAccounts' -and
        ($ClientId -ne [guid]::Empty -or $null -ne $ClientSecret -or $null -ne $ClientCertificate)) {
        throw (New-InventoryError 'AzAccounts mode does not accept client credentials. Select ClientSecret or Certificate mode.')
    }
    if ($AuthenticationMode -ne 'AzAccounts' -and $UseExistingContext) {
        throw (New-InventoryError 'UseExistingContext applies only to AzAccounts authentication.')
    }
    $root = [System.IO.Path]::GetFullPath($OutputDirectory)
    if ($root -match '[\r\n]') { throw (New-InventoryError 'Output directory cannot contain line breaks.') }
    [System.IO.Directory]::CreateDirectory($root) | Out-Null
    $lock = [System.IO.File]::Open(
        (Join-Path $root '.inventory.lock'), [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None
    )
    $session = $null
    $checkpoint = $null
    $initialized = $false
    try {
        $checkpointPath = Join-Path $root 'checkpoint.json'
        $fingerprint = Get-Sha256 ("$script:FormatVersion|$tenant|Commercial|$script:ApiVersion|$PageSize|$root")
        if ($Resume) {
            $checkpoint = Read-JsonFile $checkpointPath
            if ($checkpoint.FormatVersion -ne $script:FormatVersion -or $checkpoint.Fingerprint -ne $fingerprint) {
                throw (New-InventoryError 'Checkpoint tenant, cloud, output path, page size, or format does not match this invocation.')
            }
            Get-SourceStates $root | ForEach-Object { Assert-SourceIntegrity $_.Directory $_.State }
            $summaryPath = Join-Path $root 'RunSummary.json'
            if ([System.IO.File]::Exists($summaryPath)) {
                $previous = Read-JsonFile $summaryPath
                if ($previous.ReportsCurrent) {
                    if ($previous.RunId -ne $checkpoint.RunId -or $previous.TenantId -ine $tenant -or
                        $previous.ReportHashes.Count -ne 6) {
                        throw (New-InventoryError 'The report summary does not match this checkpoint.')
                    }
                    foreach ($name in $previous.ReportHashes.Keys) {
                        if ($name -notin @('AllApps.csv', 'PremiumApps.csv', 'ReviewApps.csv', 'Environments.csv', 'Coverage.csv', 'Failures.csv') -or
                            $previous.ReportHashes[$name] -ne (Get-FileDigest (Join-Path $root $name))) {
                            throw (New-InventoryError 'A report was changed or lost since its committed summary. Restore it or use a new output directory.')
                        }
                    }
                }
            }
        }
        else {
            foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($root)) {
                if ([System.IO.Path]::GetFileName($entry) -ne '.inventory.lock') {
                    throw (New-InventoryError 'Use an empty output directory, or specify Resume for an existing inventory.')
                }
            }
            $checkpoint = [ordered]@{
                FormatVersion = $script:FormatVersion; Fingerprint = $fingerprint
                TenantId = $tenant; Cloud = 'Commercial'; RunId = [guid]::NewGuid().ToString()
                StartedUtc = (& $Clock).ToString('o')
            }
            Write-AtomicJson $checkpointPath $checkpoint
        }
        $initialized = $true
        Write-AtomicJson (Join-Path $root 'RunSummary.json') @{
            Status = 'Running'; ExitCode = 1; ReportsCurrent = $false
            RunId = $checkpoint.RunId; TenantId = $tenant; StartedUtc = $checkpoint.StartedUtc
        }
        $session = @{
            Root = $root; TenantId = $tenant; PageSize = $PageSize
            RequestIntervalMilliseconds = $RequestIntervalMilliseconds
            MaxRetries = $MaxRetries; RetryBudgetSeconds = $RetryBudgetSeconds
            RequestTimeoutSeconds = $RequestTimeoutSeconds
            TokenProvider = $TokenProvider; Transport = $Transport; Sleep = $Sleep; Clock = $Clock
            FaultHook = $FaultHook; Tokens = @{}; NotBefore = [DateTimeOffset]::MinValue
            NativeWebRunner = $null; NativeAuthState = $null
            AuthenticationMode = $AuthenticationMode
            Requests = 0L; Halt = $false; PrincipalId = ''
        }
        if ($null -eq $TokenProvider) {
            if ($AuthenticationMode -eq 'AzAccounts') {
                $session.TokenProvider = New-AzTokenProvider $tenant -UseExistingContext:$UseExistingContext
            }
            else {
                $session.NativeAuthState = New-NativeAuthState -Session $session -Mode $AuthenticationMode `
                    -ClientId $ClientId -ClientSecret $ClientSecret -ClientCertificate $ClientCertificate `
                    -RedirectUri $RedirectUri -LoginTimeoutSeconds $LoginTimeoutSeconds `
                    -CodeReceiver $AuthCodeReceiver -TokenRequest $AuthTokenRequest
                $nativeState = $session.NativeAuthState
                $nativeTokenCommand = ${function:Get-NativeAccessToken}
                $session.TokenProvider = {
                    param($Audience)
                    & $nativeTokenCommand $nativeState $Audience
                }.GetNewClosure()
            }
        }
        Get-SessionToken $session $script:ApiRoot | Out-Null
        $environments = Invoke-Source $session (New-SourceSpec 'InventoryEnvironments' $tenant)
        if (-not $session.Halt) {
            Invoke-Source $session (New-SourceSpec 'InventoryApps' $tenant) | Out-Null
        }
        Read-StagedRows $environments.Directory $environments.State | ForEach-Object {
            $environment = $_
            if ($environment.Scope -ne 'Excluded' -and -not $session.Halt) {
                Invoke-Source $session (New-SourceSpec 'AdminApps' $tenant $environment -PageSize $PageSize) | Out-Null
                if (-not $session.Halt) {
                    $detail = Invoke-Source $session (New-SourceSpec 'EnvironmentDetail' $tenant $environment)
                    if ($detail.State.Complete -and -not $session.Halt) {
                        $metadata = Read-StagedRows $detail.Directory $detail.State
                        Invoke-Source $session (New-SourceSpec 'DataversePublished' $tenant $environment $metadata.DataverseUrl) | Out-Null
                        if (-not $session.Halt) {
                            Invoke-Source $session (New-SourceSpec 'DataverseUnpublished' $tenant $environment $metadata.DataverseUrl) | Out-Null
                        }
                    }
                }
            }
        }
        return Export-InventoryReports $session $checkpoint
    }
    catch {
        if ($initialized) {
            Write-AtomicJson (Join-Path $root 'RunSummary.json') @{
                Status = 'Failed'; ExitCode = 1; ReportsCurrent = $false
                TenantId = $tenant; RunId = $checkpoint.RunId; StartedUtc = $checkpoint.StartedUtc
                Message = 'The scan stopped. Committed source pages are retained. Resolve the reported error and resume.'
            }
        }
        throw
    }
    finally {
        if ($null -ne $session) {
            $session.Tokens.Clear()
            if ($null -ne $session.NativeAuthState) { Close-NativeAuthState $session.NativeAuthState }
            if ($null -ne $session.NativeWebRunner) { $session.NativeWebRunner.Dispose() }
            $session.TokenProvider = $null
        }
        $lock.Dispose()
    }
}

function ConvertTo-InventoryRecord {
    param($Row, $Spec, [string]$TenantId)
    $kind = $Spec.Kind
    $properties = Get-Field $Row 'properties'
    if ($kind -in @('InventoryEnvironments', 'InventoryApps', 'EnvironmentDetail')) {
        if ((Get-Field $Row 'tenantId') -ine $TenantId) {
            throw (New-InventoryError "Missing or mismatched tenantId in $kind response.")
        }
    }
    if ($kind -eq 'InventoryEnvironments') {
        $environmentId = [string](Get-Field $Row 'name')
        Assert-Identifier $environmentId 'environment ID'
        $managed = Get-ManagedState (Get-Field $properties 'isManaged')
        $type = [string](Get-Field $properties 'environmentType')
        return [ordered]@{
            Key = $environmentId.ToLowerInvariant() + '|0'; RowKind = 'Environment'
            EnvironmentId = $environmentId; EnvironmentName = [string](Get-Field $properties 'displayName')
            EnvironmentType = $type; ManagedState = $managed
            Scope = Get-EnvironmentScope $type $managed
            Location = [string](Get-Field $Row 'location')
        }
    }
    if ($kind -eq 'EnvironmentDetail') {
        if ((Get-Field $Row 'id') -ine $Spec.EnvironmentId) {
            throw (New-InventoryError 'The environment detail response belongs to a different environment.')
        }
        $url = [string](Get-Field $Row 'url')
        if (-not $url) {
            throw (New-InventoryError 'No Dataverse URL was returned. Dataverse may be unprovisioned or inaccessible; model-driven coverage cannot be established.')
        }
        return [ordered]@{
            Key = $Spec.EnvironmentId.ToLowerInvariant() + '|2'; RowKind = 'Metadata'
            DataverseUrl = Assert-DataverseUrl $url
        }
    }
    $environment = $Spec.Environment
    $appType = ''
    $subType = ''
    $ownerId = ''; $ownerName = ''; $ownerEmail = ''; $creatorId = ''
    $created = ''; $modified = ''; $premium = 'Unknown'; $published = ''
    $evidence = 'No authoritative premium evidence; review app dependencies, including called flows.'
    $resourceId = [string](Get-Field $Row 'id')
    if ($kind -eq 'InventoryApps') {
        $appId = [string](Get-Field $properties 'appModuleId')
        $appType = [string](Get-Field $Row 'type')
        if (-not $appId -or $appType -ine 'microsoft.powerapps/modeldrivenapps') {
            $appId = [string](Get-Field $Row 'name')
        }
        $environmentId = [string](Get-Field $properties 'environmentId')
        if ($environmentId) { Assert-Identifier $environmentId 'app environment ID' }
        $managed = Get-ManagedState (Get-Field $Row 'isManagedEnvironment')
        $environmentType = [string](Get-Field $Row 'environmentType')
        $environment = @{
            EnvironmentId = $environmentId
            EnvironmentName = [string](Get-Field $Row 'environmentName')
            EnvironmentType = $environmentType; ManagedState = $managed
            Scope = Get-EnvironmentScope $environmentType $managed
            Location = [string](Get-Field $Row 'location')
        }
        $displayName = [string](Get-Field $properties 'displayName')
        $subType = [string](Get-Field $properties 'subType')
        $ownerId = [string](Get-Field $properties 'ownerId')
        $creatorId = [string](Get-Field $properties 'createdBy')
        $created = Get-TimestampString (Get-Field $properties 'createdAt')
        $modified = Get-TimestampString (Get-Field $properties 'lastModifiedAt')
        if ($appType -ieq 'microsoft.powerapps/modeldrivenapps') { $published = 'Published' }
    }
    elseif ($kind -eq 'AdminApps') {
        $appId = [string](Get-Field $Row 'name')
        $displayName = [string](Get-Field $properties 'displayName')
        $returnedEnvironment = Get-Field $properties 'environment'
        if ($null -ne $returnedEnvironment -and (Get-Field $returnedEnvironment 'name') -and
            (Get-Field $returnedEnvironment 'name') -ine $Spec.EnvironmentId) {
            throw (New-InventoryError 'Admin Apps returned an app from a different environment.')
        }
        $owner = Get-Field $properties 'owner'
        $ownerId = [string](Get-Field $owner 'id')
        $ownerName = [string](Get-Field $owner 'displayName')
        $ownerEmail = [string](Get-Field $owner 'email')
        if (-not $ownerEmail) { $ownerEmail = [string](Get-Field $owner 'userPrincipalName') }
        $creator = Get-Field $properties 'createdBy'
        $creatorId = [string](Get-Field $creator 'id')
        $created = Get-TimestampString (Get-Field $properties 'createdTime')
        $modified = Get-TimestampString (Get-Field $properties 'lastModifiedTime')
        $references = Get-Field $properties 'connectionReferences'
        if ($references -is [System.Collections.IDictionary]) { $references = $references.Values }
        foreach ($reference in $references) {
            $reason = ''
            if ((Get-Field $reference 'apiTier') -ieq 'Premium') { $reason = 'premium connector' }
            if ((Get-Field $reference 'isCustomApiConnection') -eq $true) { $reason = 'custom connector' }
            if ((Get-Field $reference 'isOnPremiseConnection') -eq $true) { $reason = 'on-premises gateway' }
            if ($reason) {
                $premium = 'Premium'
                $evidence = "Admin Apps connectionReferences: $reason ($([string](Get-Field $reference 'id')))."
                break
            }
        }
    }
    else {
        $appId = [string](Get-Field $Row 'appmoduleid')
        $displayName = [string](Get-Field $Row 'name')
        $appType = 'microsoft.powerapps/modeldrivenapps'
        $created = Get-TimestampString (Get-Field $Row 'createdon')
        $modified = Get-TimestampString (Get-Field $Row 'modifiedon')
        $published = if ($kind -eq 'DataverseUnpublished') { 'Unpublished' } else { 'Published' }
    }
    Assert-Identifier $appId 'app ID'
    if ($appType -ieq 'microsoft.powerapps/modeldrivenapps') {
        $premium = 'Premium'
        $evidence = 'Model-driven app: Dataverse premium capability; qualifying Dynamics 365 use rights can also apply.'
    }
    elseif ($appType -ieq 'microsoft.powerapps/codeapps' -and $subType -ieq 'byocApp') {
        $premium = 'Premium'
        $evidence = 'Code app (byocApp): documented Power Apps Premium, pay-as-you-go, app pass, or auto-claim requirement.'
    }
    return [ordered]@{
        Key = $environment.EnvironmentId.ToLowerInvariant() + '|1|' + $appId.ToLowerInvariant()
        RowKind = 'App'; AppId = $appId; AppName = $displayName
        AppType = $appType; AppSubType = $subType; ResourceId = $resourceId
        OwnerObjectId = $ownerId; OwnerName = $ownerName; OwnerEmail = $ownerEmail
        CreatorObjectId = $creatorId; CreatedUtc = $created; ModifiedUtc = $modified
        EnvironmentId = $environment.EnvironmentId; EnvironmentName = $environment.EnvironmentName
        EnvironmentType = $environment.EnvironmentType; ManagedState = $environment.ManagedState
        Scope = $environment.Scope; Location = $environment.Location
        PremiumClassification = $premium; PremiumEvidence = $evidence
        PublicationState = $published; Source = $kind
    }
}

. (Join-Path $PSScriptRoot 'Authentication.ps1')

Export-ModuleMember -Function Invoke-DeveloperPremiumInventory

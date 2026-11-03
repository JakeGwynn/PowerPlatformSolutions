#Requires -Version 5.1

function ConvertTo-Base64Url {
    param([byte[]]$Bytes)
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertFrom-SecureValue {
    param([securestring]$Value)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function New-AuthRandomValue {
    $bytes = [byte[]]::new(32)
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $generator.GetBytes($bytes); return ConvertTo-Base64Url $bytes }
    finally { $generator.Dispose() }
}

function Get-AuthPkceChallenge {
    param([string]$Verifier)
    $hex = Get-Sha256 $Verifier
    $bytes = [byte[]]::new(32)
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        $bytes[$index] = [Convert]::ToByte($hex.Substring($index * 2, 2), 16)
    }
    return ConvertTo-Base64Url $bytes
}

function ConvertTo-FormBody {
    param($Fields)
    $pairs = [Collections.Generic.List[string]]::new($Fields.Count)
    foreach ($key in $Fields.Keys) {
        $pairs.Add([Uri]::EscapeDataString([string]$key) + '=' + [Uri]::EscapeDataString([string]$Fields[$key]))
    }
    return [string]::Join('&', $pairs.ToArray())
}

function ConvertFrom-FormBody {
    param([string]$Text)
    $fields = @{}
    foreach ($part in $Text.Split('&')) {
        $pair = $part.Split([char[]]'=', 2)
        if ($pair.Length -ne 2) { throw (New-InventoryError 'Malformed authentication callback.') }
        $key = [Net.WebUtility]::UrlDecode($pair[0])
        if ($fields.ContainsKey($key)) { throw (New-InventoryError 'Duplicate authentication callback parameter.') }
        $fields[$key] = [Net.WebUtility]::UrlDecode($pair[1])
    }
    return $fields
}

function Assert-AuthRedirectUri {
    param([string]$RedirectUri)
    $uri = [Uri]::new($RedirectUri, [UriKind]::Absolute)
    if ($uri.Scheme -ne 'http' -or $uri.Host -notin @('localhost', '127.0.0.1') -or
        $uri.Port -lt 1024 -or $uri.Port -gt 65535 -or $uri.Query -or $uri.Fragment -or $uri.UserInfo) {
        throw (New-InventoryError 'Use a registered HTTP loopback Web redirect URI on localhost or 127.0.0.1, with a port between 1024 and 65535.')
    }
}

function Receive-AuthCode {
    param($Authorization, [int]$TimeoutSeconds, [scriptblock]$BrowserLauncher)
    $redirect = [Uri]$Authorization.RedirectUri
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $redirect.Port)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $listener.Start()
        if ($null -ne $BrowserLauncher) { & $BrowserLauncher $Authorization.Uri }
        else { Start-Process -FilePath $Authorization.Uri -ErrorAction Stop }
        if ($null -eq $BrowserLauncher) {
            Write-Host 'Complete the Microsoft user sign-in in your browser. Credentials are not entered into this script.'
        }
        while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            if (-not $listener.Pending()) { Start-Sleep -Milliseconds 100; continue }
            $client = $listener.AcceptTcpClient()
            try {
                $stream = $client.GetStream()
                $stream.ReadTimeout = 5000
                $stream.WriteTimeout = 5000
                $buffer = [IO.MemoryStream]::new()
                try {
                    $headerEnd = -1
                    while ($buffer.Length -lt 16384 -and $headerEnd -lt 0) {
                        $next = $stream.ReadByte()
                        if ($next -lt 0) { break }
                        $buffer.WriteByte([byte]$next)
                        if ($buffer.Length -ge 4) {
                            $bytes = $buffer.GetBuffer()
                            $length = [int]$buffer.Length
                            if ($bytes[$length - 4] -eq 13 -and $bytes[$length - 3] -eq 10 -and
                                $bytes[$length - 2] -eq 13 -and $bytes[$length - 1] -eq 10) {
                                $headerEnd = $length
                            }
                        }
                    }
                    if ($headerEnd -lt 0) { throw (New-InventoryError 'The authentication callback headers were incomplete or too large.') }
                    $header = [Text.Encoding]::ASCII.GetString($buffer.ToArray())
                    $lines = $header.Split([string[]]@("`r`n"), [StringSplitOptions]::None)
                    if ($lines[0] -notmatch '^POST (/\S*) HTTP/1\.[01]$' -or
                        ([Uri]::new($redirect, $Matches[1])).AbsolutePath -cne $redirect.AbsolutePath) {
                        throw (New-InventoryError 'Unexpected authentication callback method or path.')
                    }
                    $length = -1
                    $contentType = ''
                    foreach ($line in $lines) {
                        if ($line -match '^Content-Length:\s*(\d+)\s*$') { $length = [int]$Matches[1] }
                        if ($line -match '^Content-Type:\s*(.+)\s*$') { $contentType = $Matches[1] }
                    }
                    if ($length -lt 1 -or $length -gt 16384 -or
                        $contentType -notmatch '^application/x-www-form-urlencoded(?:;|$)') {
                        throw (New-InventoryError 'Unexpected authentication callback content type or length.')
                    }
                    $body = [byte[]]::new($length)
                    $offset = 0
                    while ($offset -lt $length) {
                        $read = $stream.Read($body, $offset, $length - $offset)
                        if ($read -eq 0) { throw (New-InventoryError 'Incomplete authentication callback body.') }
                        $offset += $read
                    }
                    $fields = ConvertFrom-FormBody ($script:Utf8.GetString($body))
                    if ((Get-Field $fields 'state') -cne $Authorization.State) {
                        throw (New-InventoryError 'Authentication callback state validation failed.')
                    }
                    if (Get-Field $fields 'error') {
                        throw (New-InventoryError 'Microsoft sign-in was denied or failed. Check app registration, delegated consent, and Conditional Access.')
                    }
                    $code = [string](Get-Field $fields 'code')
                    if (-not $code) { throw (New-InventoryError 'Microsoft did not return an authorization code.') }
                    $html = '<html><body>Sign-in received. You can close this window and return to PowerShell.</body></html>'
                    $response = "HTTP/1.1 200 OK`r`nContent-Type: text/html; charset=utf-8`r`nCache-Control: no-store`r`nConnection: close`r`nContent-Length: $($html.Length)`r`n`r`n$html"
                    $bytes = $script:Utf8.GetBytes($response)
                    $stream.Write($bytes, 0, $bytes.Length)
                    return @{ Code = $code; State = $fields.state }
                }
                finally { $buffer.Dispose() }
            }
            finally { $client.Dispose() }
        }
        throw (New-InventoryError 'Microsoft user sign-in timed out. Run the inventory again when ready to sign in.')
    }
    finally { $listener.Stop() }
}

function New-ClientCertificateAssertion {
    param($State)
    $certificate = $State.Certificate
    $now = & $State.Session.Clock
    if (-not $certificate.HasPrivateKey -or $certificate.NotBefore.ToUniversalTime() -gt $now.UtcDateTime -or
        $certificate.NotAfter.ToUniversalTime() -le $now.UtcDateTime.AddMinutes(5)) {
        throw (New-InventoryError 'Use a currently valid RSA certificate with an accessible private key and at least five minutes of remaining validity.')
    }
    if ($null -eq ('System.Security.Cryptography.X509Certificates.RSACertificateExtensions' -as [type]) -or
        $null -eq ('System.Security.Cryptography.RSASignaturePadding' -as [type])) {
        throw (New-InventoryError 'Certificate mode requires the platform RSA-PSS certificate APIs. Use ClientSecret mode on older runtimes; native modes do not require Az.Accounts or .NET Framework 4.7.2.')
    }
    $key = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certificate)
    if ($null -eq $key) { throw (New-InventoryError 'The client certificate must have an RSA private key.') }
    try {
        $stream = [IO.MemoryStream]::new($certificate.RawData)
        try { $hex = (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash }
        finally { $stream.Dispose() }
        $thumbprint = [byte[]]::new(32)
        for ($index = 0; $index -lt $thumbprint.Length; $index++) {
            $thumbprint[$index] = [Convert]::ToByte($hex.Substring($index * 2, 2), 16)
        }
        $epoch = [DateTimeOffset]::Parse('1970-01-01T00:00:00+00:00')
        $issued = [long][Math]::Floor(($now - $epoch).TotalSeconds)
        $header = @{ alg = 'PS256'; typ = 'JWT'; 'x5t#S256' = ConvertTo-Base64Url $thumbprint }
        $payload = @{
            aud = $State.TokenUri; iss = $State.ClientId; sub = $State.ClientId
            jti = [guid]::NewGuid().ToString(); iat = $issued; nbf = $issued - 30; exp = $issued + 300
        }
        $unsigned = (ConvertTo-Base64Url ($script:Utf8.GetBytes((ConvertTo-InventoryJson $header)))) +
            '.' + (ConvertTo-Base64Url ($script:Utf8.GetBytes((ConvertTo-InventoryJson $payload))))
        try {
            $signature = $key.SignData($script:Utf8.GetBytes($unsigned),
                [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pss)
        }
        catch [Security.Cryptography.CryptographicException] {
            throw (New-InventoryError 'The certificate key provider cannot sign RSA-PSS assertions. Use an RSA-PSS-capable key (CNG on Windows), another certificate, or ClientSecret mode.')
        }
        return $unsigned + '.' + (ConvertTo-Base64Url $signature)
    }
    finally { $key.Dispose() }
}

function Invoke-NativeTokenRequest {
    param($State, $Fields)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $retry = 0
    while ($true) {
        $body = @{}
        foreach ($key in $Fields.Keys) { $body[$key] = $Fields[$key] }
        $body.client_id = $State.ClientId
        if ($State.Mode -eq 'ClientSecret') { $body.client_secret = ConvertFrom-SecureValue $State.Secret }
        else {
            $body.client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
            $body.client_assertion = New-ClientCertificateAssertion $State
        }
        $request = @{
            Method = 'POST'; Uri = $State.TokenUri; Headers = @{ Accept = 'application/json' }
            Body = ConvertTo-FormBody $body; ContentType = 'application/x-www-form-urlencoded'; Sensitive = $true
        }
        try {
            try {
                if ($null -ne $State.TokenRequest) { $response = & $State.TokenRequest $request }
                else { $response = Invoke-HttpTransport $State.Session $request }
                $status = [int]$response.StatusCode
            }
            catch [Net.WebException], [TimeoutException], [IO.IOException] {
                $status = 0
                $response = @{ Headers = @{} }
            }
        }
        finally { $body.Clear(); $request.Clear() }
        if ($status -ge 200 -and $status -lt 300) {
            try { return ConvertFrom-InventoryJson $response.Body }
            catch { throw (New-InventoryError 'Microsoft returned an invalid token response; no credentials were logged.') }
        }
        if ($status -notin @(0, 408, 429) -and ($status -lt 500 -or $status -gt 599 -or $status -in @(501, 505))) {
            throw (New-InventoryError "Microsoft token request failed (HTTP $status). Check the client credential, Web redirect URI, delegated API consent, and Conditional Access; then rerun the user sign-in." $status)
        }
        $delay = Get-RetryDelayMilliseconds $response.Headers $retry (& $State.Session.Clock)
        if ($retry -ge $State.Session.MaxRetries -or
            $watch.Elapsed.TotalMilliseconds + $delay -gt $State.Session.RetryBudgetSeconds * 1000) {
            throw (New-InventoryError 'Microsoft token request retry budget was exhausted; server backoff was not shortened. Retry the inventory later.' $status)
        }
        & $State.Session.Sleep $delay
        $retry++
    }
}

function Get-NativeAccessToken {
    param($State, [string]$Audience)
    if ($Audience -ne $script:ApiRoot) { Assert-DataverseUrl $Audience | Out-Null }
    $fields = @{ scope = $Audience.TrimEnd('/') + '/.default' }
    try {
        if ($null -eq $State.RefreshToken) {
            $verifier = New-AuthRandomValue
            $nonce = New-AuthRandomValue
            $authorizationFields = @{
                client_id = $State.ClientId; response_type = 'code'; response_mode = 'form_post'
                redirect_uri = $State.RedirectUri; scope = $fields.scope + ' offline_access'
                state = $nonce; code_challenge = Get-AuthPkceChallenge $verifier; code_challenge_method = 'S256'
                prompt = 'select_account'
            }
            $authorization = @{
                Uri = $State.AuthorizeUri + '?' + (ConvertTo-FormBody $authorizationFields)
                RedirectUri = $State.RedirectUri; State = $nonce
            }
            if ($null -ne $State.CodeReceiver) { $callback = & $State.CodeReceiver $authorization $State.LoginTimeoutSeconds }
            else { $callback = Receive-AuthCode $authorization $State.LoginTimeoutSeconds }
            if ((Get-Field $callback 'State') -cne $nonce -or -not (Get-Field $callback 'Code')) {
                throw (New-InventoryError 'Authentication callback state or code validation failed.')
            }
            $fields.grant_type = 'authorization_code'; $fields.code = $callback.Code
            $fields.redirect_uri = $State.RedirectUri; $fields.code_verifier = $verifier
        }
        else {
            $fields.grant_type = 'refresh_token'
            $fields.refresh_token = ConvertFrom-SecureValue $State.RefreshToken
        }
        $response = Invoke-NativeTokenRequest $State $fields
        $token = [string](Get-Field $response 'access_token')
        if (-not $token -or (Get-Field $response 'token_type') -ine 'Bearer') {
            throw (New-InventoryError 'Microsoft did not return a bearer access token.')
        }
        $refresh = [string](Get-Field $response 'refresh_token')
        if ($refresh) {
            if ($null -ne $State.RefreshToken) { $State.RefreshToken.Dispose() }
            $State.RefreshToken = ConvertTo-SecureString $refresh -AsPlainText -Force
        }
        elseif ($null -eq $State.RefreshToken) {
            throw (New-InventoryError 'Microsoft did not return an offline-access refresh token. Check delegated consent and the Web application registration.')
        }
        return $token
    }
    finally { $fields.Clear() }
}

function New-NativeAuthState {
    param(
        $Session, [string]$Mode, [guid]$ClientId, [securestring]$ClientSecret,
        [Security.Cryptography.X509Certificates.X509Certificate2]$ClientCertificate,
        [string]$RedirectUri, [int]$LoginTimeoutSeconds,
        [scriptblock]$CodeReceiver, [scriptblock]$TokenRequest
    )
    Assert-AuthRedirectUri $RedirectUri
    if ($ClientId -eq [guid]::Empty) { throw (New-InventoryError 'ClientId is required for native client-secret/certificate sign-in.') }
    if ($Mode -eq 'ClientSecret' -and ($null -eq $ClientSecret -or $ClientSecret.Length -eq 0)) {
        throw (New-InventoryError 'Provide a nonempty SecureString client secret, or use the secure interactive prompt.')
    }
    if ($Mode -eq 'Certificate' -and $null -eq $ClientCertificate) {
        throw (New-InventoryError 'Provide an RSA client certificate with an accessible private key.')
    }
    $authority = 'https://login.microsoftonline.com/' + $Session.TenantId + '/oauth2/v2.0/'
    return @{
        Session = $Session; Mode = $Mode; ClientId = $ClientId.ToString()
        Secret = $(if ($null -ne $ClientSecret) { $ClientSecret.Copy() } else { $null })
        Certificate = $ClientCertificate; RefreshToken = $null
        RedirectUri = $RedirectUri; LoginTimeoutSeconds = $LoginTimeoutSeconds
        AuthorizeUri = $authority + 'authorize'; TokenUri = $authority + 'token'
        CodeReceiver = $CodeReceiver; TokenRequest = $TokenRequest
    }
}

function Close-NativeAuthState {
    param($State)
    if ($null -ne $State.Secret) { $State.Secret.Dispose() }
    if ($null -ne $State.RefreshToken) { $State.RefreshToken.Dispose() }
    $State.Clear()
}

#requires -Version 5.1
<#
.SYNOPSIS
  Einmalig die neue Discogs-Anwendung autorisieren und OAuth-Secrets sicher bei GitHub hinterlegen.
.DESCRIPTION
  Keine fremden Module, keine Musikdateien und keine gespeicherten Tokens.
  Secret-Werte werden nur einzeln kurz in die Zwischenablage kopiert.
#>
[CmdletBinding()]
param([switch]$SelfTest)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Escape-OAuth([string]$Value) {
    return [Uri]::EscapeDataString($Value).Replace('!', '%21').Replace("'", '%27').Replace('(', '%28').Replace(')', '%29').Replace('*', '%2A')
}
function Read-MaskedValue([string]$Label) {
    $secure = Read-Host -Prompt $Label -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr); $secure.Dispose() }
}
function New-Nonce {
    $bytes = New-Object byte[] 16
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) }
    finally { $rng.Dispose() }
    return ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
}
# Only fixed-host HTTPS transports signed requests. Discogs OAuth1 uses
# PLAINTEXT signatures: escaped consumer secret, &, escaped token secret.
function Get-OAuthSignature([string]$ConsumerSecret, [string]$TokenSecret) {
    return (Escape-OAuth $ConsumerSecret) + '&' + (Escape-OAuth $TokenSecret)
}
function Parse-TokenReply([AllowEmptyString()][string]$Body) {
    # OAuth1 responses use form-urlencoded encoding, not base64url tokens.
    # Never print arbitrary response bodies, unknown fields or token values.
    if ([string]::IsNullOrWhiteSpace($Body)) { throw 'DISCOGS_OAUTH_TOKEN_PARSE_EMPTY' }
    if ($Body.Length -gt 8192) { throw 'DISCOGS_OAUTH_TOKEN_PARSE_TOO_LARGE' }
    $form = $Body.Trim().TrimStart([char]0xFEFF)
    if ($form -notmatch '(^|&)oauth_token=') {
        throw 'DISCOGS_OAUTH_TOKEN_PARSE_NOT_FORM'
    }
    $values = @{}
    foreach ($part in $form.Split([char]'&')) {
        $kv = $part.Split([char[]]@('='), 2)
        if ($kv.Count -ne 2) { throw 'DISCOGS_OAUTH_TOKEN_PARSE_FORM' }
        try {
            $name = [Uri]::UnescapeDataString($kv[0].Replace('+', ' '))
            $value = [Uri]::UnescapeDataString($kv[1].Replace('+', ' '))
        }
        catch { throw 'DISCOGS_OAUTH_TOKEN_PARSE_FORM' }
        if ([string]::IsNullOrWhiteSpace($name) -or $values.ContainsKey($name)) {
            throw 'DISCOGS_OAUTH_TOKEN_PARSE_FORM'
        }
        $values[$name] = $value
    }
    foreach ($field in @('oauth_token', 'oauth_token_secret')) {
        if (-not $values.ContainsKey($field)) {
            throw 'DISCOGS_OAUTH_TOKEN_PARSE_MISSING_FIELD'
        }
        $value = [string]$values[$field]
        # Discogs tokens can contain URL-encoded punctuation, unlike base64url.
        # Permit legitimate punctuation while rejecting control characters.
        if ($value.Length -lt 1 -or $value.Length -gt 1024 -or
            $value -match '[\x00-\x1f\x7f]') {
            throw 'DISCOGS_OAUTH_TOKEN_PARSE_INVALID_VALUE'
        }
    }
    if ($values.ContainsKey('oauth_callback_confirmed') -and
        [string]$values['oauth_callback_confirmed'] -cne 'true') {
        throw 'DISCOGS_OAUTH_TOKEN_PARSE_CALLBACK'
    }
    return $values
}
function New-OfficialDiscogsRequest([string]$Endpoint, [string]$Method,
    [string]$ConsumerKey, [string]$ConsumerSecret,
    [string]$Token = '', [string]$TokenSecret = '', [string]$Verifier = '') {
    $allowed = @{ request_token = 'GET'; access_token = 'POST'; identity = 'GET' }
    if (-not $allowed.ContainsKey($Endpoint) -or $Method -cne $allowed[$Endpoint]) {
        throw 'Unapproved OAuth resource or HTTP method.'
    }
    $url = 'https://api.discogs.com/oauth/' + $Endpoint
    $parameters = @{
        oauth_consumer_key = $ConsumerKey
        oauth_nonce = New-Nonce
        oauth_signature_method = 'PLAINTEXT'
        oauth_timestamp = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()).ToString()
        oauth_version = '1.0'
    }
    if ($Endpoint -ceq 'request_token') { $parameters['oauth_callback'] = 'oob' }
    if ($Token) { $parameters['oauth_token'] = $Token }
    if ($Verifier) { $parameters['oauth_verifier'] = $Verifier }
    $parameters['oauth_signature'] = Get-OAuthSignature $ConsumerSecret $TokenSecret
    $authorization = [Collections.Generic.List[string]]::new()
    foreach ($key in @($parameters.Keys | Sort-Object)) {
        $authorization.Add((Escape-OAuth ([string]$key)) + '="' + (Escape-OAuth ([string]$parameters[$key])) + '"')
    }
    # No inline 'if' within a hashtable member: WinPS 5.1 may execute it as a command.
    $accept = if ($Endpoint -ceq 'identity') { 'application/json' } else { '*/*' }
    $headers = @{
        Authorization = 'OAuth ' + ($authorization -join ', ')
        'User-Agent' = 'MusicMetadataQA-OAuthSetup/1.1 (+https://github.com/lxsdd/dev-infrastructure-public)'
        Accept = $accept
    }
    if ($Endpoint -ceq 'access_token' -or $Endpoint -ceq 'request_token') {
        $headers['Content-Type'] = 'application/x-www-form-urlencoded'
    }
    return @{ Url = $url; Method = $Method; Headers = $headers }
}
function Invoke-OfficialDiscogs([string]$Endpoint, [string]$Method,
    [string]$ConsumerKey, [string]$ConsumerSecret,
    [string]$Token = '', [string]$TokenSecret = '', [string]$Verifier = '',
    [scriptblock]$Transport = $null) {
    # Request preparation is covered by its own safe diagnostic. Otherwise a
    # strict-mode property error could escape the HTTP catch and be reported
    # unhelpfully as LOCAL_BOOTSTRAP_ERROR.
    try {
        $request = New-OfficialDiscogsRequest $Endpoint $Method $ConsumerKey $ConsumerSecret $Token $TokenSecret $Verifier
    }
    catch {
        throw ("DISCOGS_OAUTH_" + $Endpoint + "_PREPARE")
    }
    try {
        if ($null -ne $Transport) {
            # Offline CI only; no third-party modules or network. Real callers
            # never set Transport.
            $response = & $Transport $request
        } else {
            $response = Invoke-WebRequest -Uri $request.Url -Method $request.Method `
                -Headers $request.Headers -UseBasicParsing -TimeoutSec 25 -MaximumRedirection 0 -ErrorAction Stop
        }
        if ([int]$response.StatusCode -ne 200) { throw 'Unexpected HTTP result' }
        return [string]$response.Content
    }
    catch {
        # StrictMode Latest: many exceptions do NOT expose .Response. Accessing
        # it directly creates a SECOND error that masks the actual HTTP issue.
        # Never emit underlying HTTP exception, Authorization, tokens, or URL.
        $status = 0
        $failure = $_.Exception
        $property = $failure.PSObject.Properties['Response']
        if ($null -ne $property -and $null -ne $property.Value) {
            try {
                $statusProperty = $property.Value.PSObject.Properties['StatusCode']
                if ($null -ne $statusProperty) { $status = [int]$statusProperty.Value }
            } catch { $status = 0 }
        }
        if ($status -ge 300 -and $status -le 599) {
            throw ("DISCOGS_OAUTH_" + $Endpoint + "_HTTP_" + $status)
        }
        throw ("DISCOGS_OAUTH_" + $Endpoint + "_TRANSPORT")
    }
}
function Clear-OwnClipboard([string]$Expected) {
    if (-not $Expected) { return }
    try {
        if ((Get-Clipboard -Raw) -ceq $Expected) { Set-Clipboard -Value '' }
    } catch {
        Write-Host 'Hinweis: Zwischenablage ggf. manuell leeren.' -ForegroundColor Yellow
    }
}
function Add-EnvironmentSecretViaClipboard([string]$Name, [string]$Secret) {
    if ([string]::IsNullOrEmpty($Secret)) { throw 'Kein OAuth-Wert vorhanden.' }
    Write-Host ''
    Write-Host 'GitHub -> discogs-live-qa -> Environment secrets -> Add environment secret'
    Write-Host ('Name: ' + $Name)
    Write-Host 'Der Wert wird NICHT auf dem Bildschirm angezeigt.'
    [void](Read-Host 'Druecke ENTER, um den Wert in die Zwischenablage zu kopieren')
    Set-Clipboard -Value $Secret
    try {
        Write-Host 'Wert kopiert. Bei GitHub \"Secret\" mit Strg+V fuellen und \"Add secret\" klicken.'
        [void](Read-Host 'Sobald GitHub das Speichern bestaetigt hat, hier ENTER druecken')
    }
    finally { Clear-OwnClipboard $Secret }
}
function Run-SelfTest {
    $r = New-OfficialDiscogsRequest 'request_token' 'GET' 'synthetic_consumer_key' 'synthetic_consumer_secret'
    if ($r.Method -cne 'GET' -or $r.Url -cne 'https://api.discogs.com/oauth/request_token' -or
        $r.Headers.Accept -cne '*/*' -or
        $r.Headers.Authorization -notmatch 'oauth_signature_method="PLAINTEXT"' -or
        $r.Headers.Authorization -notmatch 'oauth_callback="oob"' -or
        $r.Headers.Authorization -notmatch 'oauth_signature="synthetic_consumer_secret%26"') {
        throw 'Request-token method or signed header regression.'
    }
    $a = New-OfficialDiscogsRequest 'access_token' 'POST' 'synthetic_key' 'consumer+ secret' 'synthetic_token_2026' 'token/secret' 'pin123'
    if ($a.Method -cne 'POST' -or
        $a.Headers.Authorization -notmatch 'oauth_verifier="pin123"' -or
        $a.Headers.Authorization -notmatch 'oauth_signature="consumer%252B%2520secret%26token%252Fsecret"' -or
        $a.Headers.Authorization.Contains('consumer+ secret') -or
        $a.Headers.Authorization.Contains('token/secret')) {
        throw 'Access-token signature, escaping or HTTP method regression.'
    }
    $i = New-OfficialDiscogsRequest 'identity' 'GET' 'synthetic_key' 'consumer_secret' 'synthetic_token_2026' 'token_secret'
    if ($i.Method -cne 'GET' -or $i.Headers.Accept -cne 'application/json') {
        throw 'Identity request or header regression.'
    }
    $denied = $false
    try { [void](New-OfficialDiscogsRequest 'request_token' 'POST' 'synthetic_key' 'synthetic_secret') }
    catch { $denied = $true }
    if (-not $denied) { throw 'Unsupported OAuth HTTP method allowed.' }
    $encoded = Parse-TokenReply ('oauth_token=ab%2Bcd%2Fef%3D%3D%21%40%3A%24%28%29' +
        '&oauth_token_secret=q%2Br%2Fs%3D%3D%40%21%25%3F&oauth_callback_confirmed=true')
    if ($encoded['oauth_token'] -cne 'ab+cd/ef==!@:$()' -or
        $encoded['oauth_token_secret'] -cne 'q+r/s==@!%?') {
        throw 'Legitimate URL-encoded token punctuation rejected'
    }
    $fromBOM = Parse-TokenReply ([char]0xFEFF + 'oauth_token=bomToken123&oauth_token_secret=bomSecret123' + [char]13 + [char]10)
    if ($fromBOM['oauth_token'] -cne 'bomToken123' -or $fromBOM['oauth_token_secret'] -cne 'bomSecret123') {
        throw 'BOM or trailing CRLF parse regression'
    }
    $extra = Parse-TokenReply 'extra_a=value&oauth_token=with.dots.12345&oauth_token_secret=with%2Fpunctuation%3D&extra_b=again'
    if ($extra['oauth_token'] -cne 'with.dots.12345' -or
        $extra['oauth_token_secret'] -cne 'with/punctuation=') {
        throw 'Form decoding or extra fields parse regression'
    }
    $parseCases = @(
        @{Body='oauth_token=x';Code='DISCOGS_OAUTH_TOKEN_PARSE_MISSING_FIELD'},
        @{Body='{"error":"no token"}';Code='DISCOGS_OAUTH_TOKEN_PARSE_NOT_FORM'},
        @{Body='oauth_token=some&oauth_token_secret=abc%0D%0Axyz';Code='DISCOGS_OAUTH_TOKEN_PARSE_INVALID_VALUE'},
        @{Body='oauth_token=a&oauth_token_secret=b&oauth_callback_confirmed=false';Code='DISCOGS_OAUTH_TOKEN_PARSE_CALLBACK'}
    )
    foreach ($case in $parseCases) {
        $blocked = $false
        try { [void](Parse-TokenReply $case.Body) }
        catch { $blocked = $_.Exception.Message -ceq $case.Code }
        if (-not $blocked) { throw 'Unsafe OAuth parser error classification' }
    }
    $parsed = Parse-TokenReply 'oauth_token=abcdefgh12345678&oauth_token_secret=abcdefghi9876543&oauth_callback_confirmed=true'
    if ($parsed['oauth_token'] -cne 'abcdefgh12345678' -or $parsed['oauth_token_secret'] -cne 'abcdefghi9876543') {
        throw 'Token response parse regression.'
    }
    $denied = $false
    try { [void](Parse-TokenReply 'oauth_token=abcdefgh12345678&oauth_token=duplicate&oauth_token_secret=abcdefghi9876543') }
    catch { $denied = $true }
    if (-not $denied) { throw 'Duplicate OAuth response token accepted.' }
    # Exercise the complete HTTP wrapper with a synthetic error and a fake
    # success, so StrictMode/catch bugs cannot evade the real Windows tests.
    $failureTransport = { param($r) throw [InvalidOperationException]::new('synthetic transport rejection') }
    $failedSafely = $false
    try {
        [void](Invoke-OfficialDiscogs 'request_token' 'GET' 'synthetic_key' 'synthetic_secret' -Transport $failureTransport)
    } catch {
        $failedSafely = $_.Exception.Message -ceq 'DISCOGS_OAUTH_request_token_TRANSPORT'
    }
    if (-not $failedSafely) { throw 'Synthetic transport error was not safely classified.' }
    $fakeSuccess = {
        param($r)
        if ($r.Url -cne 'https://api.discogs.com/oauth/request_token' -or
            $r.Headers.Authorization -notmatch 'oauth_signature_method="PLAINTEXT"') {
            throw 'Unexpected mocked OAuth request.'
        }
        return [pscustomobject]@{
            StatusCode=200
            Content='oauth_token=abcdefgh12345678&oauth_token_secret=abcdefghi9876543&oauth_callback_confirmed=true'
        }
    }
    $fakeResponse = Invoke-OfficialDiscogs 'request_token' 'GET' 'synthetic_key' 'synthetic_secret' -Transport $fakeSuccess
    $fakeParsed = Parse-TokenReply $fakeResponse
    if ($fakeParsed['oauth_token'] -cne 'abcdefgh12345678') { throw 'Mock request/response integration failed.' }
    Write-Output 'DISCOGS_LOCAL_OAUTH_BOOTSTRAP_SELFTEST=PASS'
}
if ($SelfTest) { Run-SelfTest; return }
if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { throw 'Nur Windows wird unterstuetzt.' }

$consumerKey = $null
$consumerSecret = $null
$verifier = $null
$tmp = $null
$access = $null
$stage = 'STARTUP'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Host ''
    Write-Host 'Discogs OAuth1 - einmalige Autorisierung fuer zentrale GitHub-QA'
    Write-Host 'Alle Zugangsdaten bleiben lokal im Prozess. KEINE Token im Terminal oder im Chat.'
    Write-Host 'Halte die Entwicklerseite deiner neuen Discogs-Anwendung bereit.'
    Write-Host ''
    $stage = 'READ_CONSUMER_KEY'
    $consumerKey = Read-MaskedValue 'Consumer Key der neuen Discogs-Anwendung (verdeckt)'
    $stage = 'READ_CONSUMER_SECRET'
    $consumerSecret = Read-MaskedValue 'Consumer Secret derselben Anwendung (verdeckt)'
    $stage = 'VALIDATE_CONSUMER'
    if ($consumerKey -cnotmatch '^[A-Za-z0-9_-]{8,512}$' -or
        $consumerSecret -cnotmatch '^[A-Za-z0-9_-]{8,512}$') {
        throw 'Consumer-Key/-Secret fehlt oder hat ein unerwartetes Format.'
    }
    Write-Host 'Fordere einen temporaeren OAuth-Antrag bei Discogs an ...'
    $stage = 'REQUEST_TOKEN_SEND'
    $tokenResponse = Invoke-OfficialDiscogs 'request_token' 'GET' $consumerKey $consumerSecret
    $stage = 'REQUEST_TOKEN_PARSE'
    $tmp = Parse-TokenReply $tokenResponse
    $tokenResponse = $null
    $authUrl = 'https://www.discogs.com/oauth/authorize?oauth_token=' + (Escape-OAuth ([string]$tmp['oauth_token']))
    Write-Host 'Oeffne den Discogs-Autorisierungsdialog in deinem Browser ...'
    $stage = 'OPEN_AUTH_BROWSER'
    Start-Process $authUrl
    Write-Host 'Pruefe www.discogs.com und den Anwendungsnamen Music Metadata QA.'
    Write-Host 'Bestaetige den Zugriff und gib den angezeigten PIN NUR hier in PowerShell ein.'
    $stage = 'READ_PIN'
    $verifier = Read-MaskedValue 'Discogs OAuth PIN (verdeckt)'
    if ($verifier -cnotmatch '^[A-Za-z0-9_-]{3,128}$') { throw 'PIN-Format ungueltig.' }
    Write-Host 'Tausche PIN bei Discogs gegen ein OAuth-Access-Paar aus ...'
    $stage = 'ACCESS_TOKEN_SEND'
    $accessResponse = Invoke-OfficialDiscogs 'access_token' 'POST' $consumerKey $consumerSecret ([string]$tmp['oauth_token']) ([string]$tmp['oauth_token_secret']) $verifier
    $stage = 'ACCESS_TOKEN_PARSE'
    $access = Parse-TokenReply $accessResponse
    $accessResponse = $null
    $stage = 'IDENTITY_REQUEST'
    $rawIdentity = Invoke-OfficialDiscogs 'identity' 'GET' $consumerKey $consumerSecret ([string]$access['oauth_token']) ([string]$access['oauth_token_secret'])
    $stage = 'IDENTITY_PARSE'
    $identity = $rawIdentity | ConvertFrom-Json
    if ($null -eq $identity -or $null -eq $identity.id) { throw 'Discogs-Identitaetspruefung fehlgeschlagen.' }
    Write-Host 'PASS: Discogs OAuth1 genehmigt und Identitaetsabfrage erfolgreich.'
    Write-Host 'Jetzt beide Werte einzeln in GitHub Environment Secrets uebernehmen.'
    $stage = 'OPEN_GITHUB'
    Start-Process 'https://github.com/lxsdd/dev-infrastructure-public/settings/environments'
    $stage = 'SAVE_ACCESS_TOKEN'
    Add-EnvironmentSecretViaClipboard 'DISCOGS_OAUTH_ACCESS_TOKEN' ([string]$access['oauth_token'])
    $stage = 'SAVE_TOKEN_SECRET'
    Add-EnvironmentSecretViaClipboard 'DISCOGS_OAUTH_TOKEN_SECRET' ([string]$access['oauth_token_secret'])
    Write-Host ''
    Write-Host 'PASS: Lokale Einrichtung abgeschlossen. Fenster kann geschlossen werden.'
}
catch {
    # Never print raw PowerShell/HTTP exceptions or signed request headers.
    Write-Host 'Einrichtung nicht abgeschlossen. Keine automatischen GitHub-Aenderungen.' -ForegroundColor Yellow
    $diagnostic = [string]$_.Exception.Message
    if ($diagnostic -cmatch '^DISCOGS_OAUTH_(request_token|access_token|identity)_(HTTP_[3-5][0-9]{2}|TRANSPORT|PREPARE)
        Write-Host ('Sicherer Diagnosecode: ' + $diagnostic)
    } else {
        if ($stage -cmatch '^(STARTUP|READ_CONSUMER_KEY|READ_CONSUMER_SECRET|VALIDATE_CONSUMER|REQUEST_TOKEN_SEND|REQUEST_TOKEN_PARSE|OPEN_AUTH_BROWSER|READ_PIN|ACCESS_TOKEN_SEND|ACCESS_TOKEN_PARSE|IDENTITY_REQUEST|IDENTITY_PARSE|OPEN_GITHUB|SAVE_ACCESS_TOKEN|SAVE_TOKEN_SECRET)$') {
            Write-Host ('Sicherer Diagnosecode: LOCAL_BOOTSTRAP_' + $stage)
        } else {
            Write-Host 'Sicherer Diagnosecode: LOCAL_BOOTSTRAP_UNKNOWN'
        }
    }
    Write-Host 'Bitte nur den Diagnosecode, nie den Token oder Secret-Wert, weitergeben.'
    exit 1
}
finally {
    Remove-Variable consumerKey, consumerSecret, verifier, tmp, access, rawIdentity, identity, authUrl -ErrorAction SilentlyContinue
}
 -or
        $diagnostic -cmatch '^DISCOGS_OAUTH_TOKEN_PARSE_(EMPTY|TOO_LARGE|NOT_FORM|FORM|MISSING_FIELD|INVALID_VALUE|CALLBACK)
        Write-Host ('Sicherer Diagnosecode: ' + $diagnostic)
    } else {
        if ($stage -cmatch '^(STARTUP|READ_CONSUMER_KEY|READ_CONSUMER_SECRET|VALIDATE_CONSUMER|REQUEST_TOKEN_SEND|REQUEST_TOKEN_PARSE|OPEN_AUTH_BROWSER|READ_PIN|ACCESS_TOKEN_SEND|ACCESS_TOKEN_PARSE|IDENTITY_REQUEST|IDENTITY_PARSE|OPEN_GITHUB|SAVE_ACCESS_TOKEN|SAVE_TOKEN_SECRET)$') {
            Write-Host ('Sicherer Diagnosecode: LOCAL_BOOTSTRAP_' + $stage)
        } else {
            Write-Host 'Sicherer Diagnosecode: LOCAL_BOOTSTRAP_UNKNOWN'
        }
    }
    Write-Host 'Bitte nur den Diagnosecode, nie den Token oder Secret-Wert, weitergeben.'
    exit 1
}
finally {
    Remove-Variable consumerKey, consumerSecret, verifier, tmp, access, rawIdentity, identity, authUrl -ErrorAction SilentlyContinue
}
) {
        Write-Host ('Sicherer Diagnosecode: ' + $diagnostic)
    } else {
        if ($stage -cmatch '^(STARTUP|READ_CONSUMER_KEY|READ_CONSUMER_SECRET|VALIDATE_CONSUMER|REQUEST_TOKEN_SEND|REQUEST_TOKEN_PARSE|OPEN_AUTH_BROWSER|READ_PIN|ACCESS_TOKEN_SEND|ACCESS_TOKEN_PARSE|IDENTITY_REQUEST|IDENTITY_PARSE|OPEN_GITHUB|SAVE_ACCESS_TOKEN|SAVE_TOKEN_SECRET)$') {
            Write-Host ('Sicherer Diagnosecode: LOCAL_BOOTSTRAP_' + $stage)
        } else {
            Write-Host 'Sicherer Diagnosecode: LOCAL_BOOTSTRAP_UNKNOWN'
        }
    }
    Write-Host 'Bitte nur den Diagnosecode, nie den Token oder Secret-Wert, weitergeben.'
    exit 1
}
finally {
    Remove-Variable consumerKey, consumerSecret, verifier, tmp, access, rawIdentity, identity, authUrl -ErrorAction SilentlyContinue
}

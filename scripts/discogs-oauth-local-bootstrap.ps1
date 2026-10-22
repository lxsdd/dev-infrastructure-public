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
function Parse-TokenReply([string]$Body) {
    if ($Body.Length -gt 8192) { throw 'Discogs-OAuth-Antwort zu gross.' }
    $values = @{}
    foreach ($part in $Body.Split('&')) {
        $kv = $part.Split('=', 2)
        if ($kv.Count -ne 2) { throw 'Discogs-OAuth-Antwort unvollstaendig.' }
        $name = [Uri]::UnescapeDataString($kv[0].Replace('+', ' '))
        if ($values.ContainsKey($name)) { throw 'Doppeltes OAuth-Feld verweigert.' }
        $values[$name] = [Uri]::UnescapeDataString($kv[1].Replace('+', ' '))
    }
    foreach ($field in @('oauth_token', 'oauth_token_secret')) {
        if (-not $values.ContainsKey($field) -or
            [string]$values[$field] -cnotmatch '^[A-Za-z0-9_-]{8,512}$') {
            throw 'Ungueltiger oder fehlender OAuth-Wert.'
        }
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
    return @{ Url = $url; Method = $Method; Headers = $headers }
}
function Invoke-OfficialDiscogs([string]$Endpoint, [string]$Method,
    [string]$ConsumerKey, [string]$ConsumerSecret,
    [string]$Token = '', [string]$TokenSecret = '', [string]$Verifier = '') {
    $request = New-OfficialDiscogsRequest $Endpoint $Method $ConsumerKey $ConsumerSecret $Token $TokenSecret $Verifier
    try {
        $response = Invoke-WebRequest -Uri $request.Url -Method $request.Method -Headers $request.Headers -UseBasicParsing -TimeoutSec 25 -MaximumRedirection 0
        if ([int]$response.StatusCode -ne 200) { throw 'Unexpected HTTP result' }
        return [string]$response.Content
    }
    catch {
        # Do not print the raw error: SDK messages may reveal Authorization headers.
        $status = 0
        if ($null -ne $_.Exception.Response) {
            try { $status = [int]$_.Exception.Response.StatusCode }
            catch { $status = 0 }
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
    $parsed = Parse-TokenReply 'oauth_token=abcdefgh12345678&oauth_token_secret=abcdefghi9876543&oauth_callback_confirmed=true'
    if ($parsed['oauth_token'] -cne 'abcdefgh12345678' -or $parsed['oauth_token_secret'] -cne 'abcdefghi9876543') {
        throw 'Token response parse regression.'
    }
    $denied = $false
    try { [void](Parse-TokenReply 'oauth_token=abcdefgh12345678&oauth_token=duplicate&oauth_token_secret=abcdefghi9876543') }
    catch { $denied = $true }
    if (-not $denied) { throw 'Duplicate OAuth response token accepted.' }
    Write-Output 'DISCOGS_LOCAL_OAUTH_BOOTSTRAP_SELFTEST=PASS'
}
if ($SelfTest) { Run-SelfTest; return }
if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { throw 'Nur Windows wird unterstuetzt.' }

$consumerKey = $null
$consumerSecret = $null
$verifier = $null
$tmp = $null
$access = $null
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Host ''
    Write-Host 'Discogs OAuth1 - einmalige Autorisierung fuer zentrale GitHub-QA'
    Write-Host 'Alle Zugangsdaten bleiben lokal im Prozess. KEINE Token im Terminal oder im Chat.'
    Write-Host 'Halte die Entwicklerseite deiner neuen Discogs-Anwendung bereit.'
    Write-Host ''
    $consumerKey = Read-MaskedValue 'Consumer Key der neuen Discogs-Anwendung (verdeckt)'
    $consumerSecret = Read-MaskedValue 'Consumer Secret derselben Anwendung (verdeckt)'
    if ($consumerKey -cnotmatch '^[A-Za-z0-9_-]{8,512}$' -or
        $consumerSecret -cnotmatch '^[A-Za-z0-9_-]{8,512}$') {
        throw 'Consumer-Key/-Secret fehlt oder hat ein unerwartetes Format.'
    }
    Write-Host 'Fordere einen temporaeren OAuth-Antrag bei Discogs an ...'
    $tmp = Parse-TokenReply (Invoke-OfficialDiscogs 'request_token' 'GET' $consumerKey $consumerSecret)
    $authUrl = 'https://www.discogs.com/oauth/authorize?oauth_token=' + (Escape-OAuth ([string]$tmp['oauth_token']))
    Write-Host 'Oeffne den Discogs-Autorisierungsdialog in deinem Browser ...'
    Start-Process $authUrl
    Write-Host 'Pruefe www.discogs.com und den Anwendungsnamen Music Metadata QA.'
    Write-Host 'Bestaetige den Zugriff und gib den angezeigten PIN NUR hier in PowerShell ein.'
    $verifier = Read-MaskedValue 'Discogs OAuth PIN (verdeckt)'
    if ($verifier -cnotmatch '^[A-Za-z0-9_-]{3,128}$') { throw 'PIN-Format ungueltig.' }
    Write-Host 'Tausche PIN bei Discogs gegen ein OAuth-Access-Paar aus ...'
    $access = Parse-TokenReply (Invoke-OfficialDiscogs 'access_token' 'POST' $consumerKey $consumerSecret ([string]$tmp['oauth_token']) ([string]$tmp['oauth_token_secret']) $verifier)
    $rawIdentity = Invoke-OfficialDiscogs 'identity' 'GET' $consumerKey $consumerSecret ([string]$access['oauth_token']) ([string]$access['oauth_token_secret'])
    $identity = $rawIdentity | ConvertFrom-Json
    if ($null -eq $identity -or $null -eq $identity.id) { throw 'Discogs-Identitaetspruefung fehlgeschlagen.' }
    Write-Host 'PASS: Discogs OAuth1 genehmigt und Identitaetsabfrage erfolgreich.'
    Write-Host 'Jetzt beide Werte einzeln in GitHub Environment Secrets uebernehmen.'
    Start-Process 'https://github.com/lxsdd/dev-infrastructure-public/settings/environments'
    Add-EnvironmentSecretViaClipboard 'DISCOGS_OAUTH_ACCESS_TOKEN' ([string]$access['oauth_token'])
    Add-EnvironmentSecretViaClipboard 'DISCOGS_OAUTH_TOKEN_SECRET' ([string]$access['oauth_token_secret'])
    Write-Host ''
    Write-Host 'PASS: Lokale Einrichtung abgeschlossen. Fenster kann geschlossen werden.'
}
catch {
    # NEVER print exception details: may include sensitive data from infrastructure.
    Write-Host 'Einrichtung nicht abgeschlossen. Keine automatischen GitHub-Aenderungen.' -ForegroundColor Yellow
    # Only preformatted, regex-validated status codes may be printed.
    $diagnostic = [string]$_.Exception.Message
    if ($diagnostic -cmatch '^DISCOGS_OAUTH_(request_token|access_token|identity)_(HTTP_[3-5][0-9]{2}|TRANSPORT)
    exit 1
}
finally {
    Remove-Variable consumerKey, consumerSecret, verifier, tmp, access, rawIdentity, identity, authUrl -ErrorAction SilentlyContinue
}
) {
        Write-Host ('Sicherer Diagnosecode: ' + $diagnostic)
    } else {
        Write-Host 'Sicherer Diagnosecode: LOCAL_BOOTSTRAP_ERROR'
    }
    Write-Host 'Bitte nur den Diagnosecode, nie den Token oder Secret-Wert, weitergeben.'
    exit 1
}
finally {
    Remove-Variable consumerKey, consumerSecret, verifier, tmp, access, rawIdentity, identity, authUrl -ErrorAction SilentlyContinue
}

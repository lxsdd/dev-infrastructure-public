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
function Get-OAuthSignature([string]$Method, [string]$Url, [hashtable]$Params,
                            [string]$ConsumerSecret, [string]$TokenSecret) {
    $pairs = [Collections.Generic.List[string]]::new()
    foreach ($key in $Params.Keys) {
        $pairs.Add((Escape-OAuth ([string]$key)) + '=' + (Escape-OAuth ([string]$Params[$key])))
    }
    $sorted = $pairs.ToArray()
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    $baseString = (Escape-OAuth ($Method.ToUpperInvariant())) + '&' +
        (Escape-OAuth $Url) + '&' + (Escape-OAuth ($sorted -join '&'))
    $secret = (Escape-OAuth $ConsumerSecret) + '&' + (Escape-OAuth $TokenSecret)
    $hmac = [Security.Cryptography.HMACSHA1]::new([Text.Encoding]::UTF8.GetBytes($secret))
    try { return [Convert]::ToBase64String($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($baseString))) }
    finally { $hmac.Dispose() }
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
function Invoke-OfficialDiscogs([string]$Endpoint, [string]$Method,
    [string]$ConsumerKey, [string]$ConsumerSecret,
    [string]$Token = '', [string]$TokenSecret = '', [string]$Verifier = '') {
    if ($Endpoint -cnotin @('request_token', 'access_token', 'identity')) {
        throw 'Ungueltige OAuth-Ressource.'
    }
    $url = 'https://api.discogs.com/oauth/' + $Endpoint
    $parameters = @{
        oauth_consumer_key = $ConsumerKey
        oauth_nonce = New-Nonce
        oauth_signature_method = 'HMAC-SHA1'
        oauth_timestamp = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()).ToString()
        oauth_version = '1.0'
    }
    if ($Endpoint -ceq 'request_token') { $parameters['oauth_callback'] = 'oob' }
    if ($Token) { $parameters['oauth_token'] = $Token }
    if ($Verifier) { $parameters['oauth_verifier'] = $Verifier }
    $parameters['oauth_signature'] = Get-OAuthSignature $Method $url $parameters $ConsumerSecret $TokenSecret
    $authorization = [Collections.Generic.List[string]]::new()
    foreach ($key in @($parameters.Keys | Sort-Object)) {
        $authorization.Add((Escape-OAuth ([string]$key)) + '="' + (Escape-OAuth ([string]$parameters[$key])) + '"')
    }
    $headers = @{
        Authorization = 'OAuth ' + ($authorization -join ', ')
        'User-Agent' = 'MusicMetadataQA-OAuthSetup/1.0 (+https://github.com/lxsdd/dev-infrastructure-public)'
        Accept = if ($Endpoint -ceq 'identity') { 'application/json' } else { '*/*' }
    }
    try {
        $response = Invoke-WebRequest -Uri $url -Method $Method -Headers $headers -UseBasicParsing -TimeoutSec 25 -MaximumRedirection 0
        if ([int]$response.StatusCode -ne 200) { throw 'Incorrect response status' }
        return [string]$response.Content
    }
    catch {
        # HTTP exceptions can contain request metadata or signatures. Suppress details.
        throw "Anfrage an Discogs '$Endpoint' fehlgeschlagen; pruefe die Anwendung. Details absichtlich unterdrueckt."
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
    $p = @{
        oauth_consumer_key = 'test_key_2026'
        oauth_nonce = 'fixed_nonce_1234'
        oauth_signature_method = 'HMAC-SHA1'
        oauth_timestamp = '1470000000'
        oauth_version = '1.0'
        oauth_callback = 'oob'
    }
    $s = Get-OAuthSignature 'POST' 'https://api.discogs.com/oauth/request_token' $p 'synthetic_consumer_secret' ''
    if ($s -cne 'sfcCgtyhuqUTw22kIYDOas09YrI=') { throw 'Signaturtest fehlgeschlagen' }
    $parsed = Parse-TokenReply 'oauth_token=abcdefgh12345678&oauth_token_secret=abcdefghi9876543&oauth_callback_confirmed=true'
    if ($parsed['oauth_token'] -cne 'abcdefgh12345678' -or $parsed['oauth_token_secret'] -cne 'abcdefghi9876543') {
        throw 'Token-Parser fehlgeschlagen'
    }
    try {
        [void](Parse-TokenReply 'oauth_token=abcdefgh12345678&oauth_token=duplicate&oauth_token_secret=abcdefghi9876543')
        throw 'Duplicate token accepted'
    } catch {
        if ($_.Exception.Message -eq 'Duplicate token accepted') { throw }
    }
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
    $tmp = Parse-TokenReply (Invoke-OfficialDiscogs 'request_token' 'POST' $consumerKey $consumerSecret)
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
    Write-Host 'Pruefe Discogs-App, Browserfreigabe und PIN.'
    exit 1
}
finally {
    Remove-Variable consumerKey, consumerSecret, verifier, tmp, access, rawIdentity, identity, authUrl -ErrorAction SilentlyContinue
}

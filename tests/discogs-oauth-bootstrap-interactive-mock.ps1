#requires -Version 5.1
# No actual credentials, network, browser, music files or operating-system clipboard.
# End-to-end simulation of local PowerShell prompt -> official OAuth responses ->
# fake GitHub secret clipboard confirmations. Original script runs unchanged.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:QAPrompts=0
$script:QACalls=[Collections.Generic.List[string]]::new()
$script:QAUrls=[Collections.Generic.List[string]]::new()
$script:QAClipboard=''
$script:QACopied=[Collections.Generic.List[string]]::new()
$script:QACleared=0

function global:Read-Host {
    [CmdletBinding()]
    param([string]$Prompt,[switch]$AsSecureString)
    if (-not $AsSecureString) {return ''}
    $script:QAPrompts++
    $v = switch($script:QAPrompts) {
        1 { 'syntheticconsumerkey2026' }
        2 { 'syntheticconsumersecret2026' }
        3 { 'pin2026' }
        default {throw 'Unrequested private prompt'}
    }
    return ConvertTo-SecureString -String $v -AsPlainText -Force
}
function global:Invoke-WebRequest {
    [CmdletBinding()]
    param([string]$Uri,[string]$Method,[hashtable]$Headers,
          [switch]$UseBasicParsing,[int]$TimeoutSec,[int]$MaximumRedirection)
    if ($Uri -cnotmatch '^https://api\.discogs\.com/oauth/(request_token|access_token|identity)$' -or
        $Headers.Authorization -notmatch 'oauth_signature_method="PLAINTEXT"' -or
        $Headers.Authorization -match 'syntheticconsumersecret2026' -and
        $Headers.Authorization -notmatch 'oauth_signature="syntheticconsumersecret2026%26') {
        throw 'Fake transport received unsafe or unrecognized official OAuth request'
    }
    $script:QACalls.Add($Method + ' ' + $Uri)
    if ($Uri.EndsWith('/request_token')) {
        if ($Method -cne 'GET') {throw 'Wrong request-token method'}
        return [pscustomobject]@{StatusCode=200;Content='oauth_token=tempToken12345&oauth_token_secret=tempSecret12345&oauth_callback_confirmed=true'}
    }
    if ($Uri.EndsWith('/access_token')) {
        if ($Method -cne 'POST' -or
            $Headers.Authorization -notmatch 'oauth_verifier="pin2026"') {throw 'Wrong access-token request'}
        return [pscustomobject]@{StatusCode=200;Content='oauth_token=accessToken12345&oauth_token_secret=accessSecret12345'}
    }
    if ($Method -cne 'GET') {throw 'Wrong identity request'}
    return [pscustomobject]@{StatusCode=200;Content='{"id":1234567}'}
}
function global:Start-Process {
    [CmdletBinding()]
    param([string]$FilePath)
    if ($FilePath -cnotmatch '^https://(www\.discogs\.com/oauth/authorize\?oauth_token=|github\.com/lxsdd/dev-infrastructure-public/settings/environments)') {
        throw 'Unexpected browser URL in fake scenario'
    }
    $script:QAUrls.Add($FilePath)
}
function global:Set-Clipboard {
    [CmdletBinding()]
    param([string]$Value)
    if ($Value -ne '') { $script:QACopied.Add($Value) }
    else { $script:QACleared++ }
    $script:QAClipboard=$Value
}
function global:Get-Clipboard {
    [CmdletBinding()]
    param([switch]$Raw)
    return $script:QAClipboard
}
try {
    . (Join-Path $PSScriptRoot '../scripts/discogs-oauth-local-bootstrap.ps1')
    if ($script:QAPrompts -ne 3 -or $script:QACalls.Count -ne 3 -or
        $script:QAUrls.Count -ne 2 -or $script:QACopied.Count -ne 2 -or
        $script:QACleared -ne 2 -or $script:QAClipboard -cne '') {
        throw 'Bootstrap did not finish all simulated workflow actions or clipboard cleanup'
    }
    if ($script:QACopied[0] -cne 'accessToken12345' -or
        $script:QACopied[1] -cne 'accessSecret12345') {
        throw 'Bootstrap did not preserve the synthetic OAuth access pair'
    }
    Write-Output 'DISCOGS_LOCAL_OAUTH_FULL_INTERACTIVE_MOCK=PASS'
}
finally {
    foreach($name in @('Read-Host','Invoke-WebRequest','Start-Process','Set-Clipboard','Get-Clipboard')) {
        Remove-Item ('Function:\global:'+ $name) -Force -ErrorAction SilentlyContinue
    }
}

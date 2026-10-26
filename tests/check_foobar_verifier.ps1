# Public synthetic acceptance tests for the canonical foobar2000 component archive verifier.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$VerifierPath)
$ErrorActionPreference = 'Stop'
$verifier = (Resolve-Path -LiteralPath $VerifierPath).Path
$work = Join-Path $env:RUNNER_TEMP ('portable-foobar-synthetic-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null
function New-TestPe([string]$Path, [UInt16]$Machine) {
    $bytes = New-Object byte[] 512
    $bytes[0] = 0x4D; $bytes[1] = 0x5A
    [BitConverter]::GetBytes([Int32]0x80).CopyTo($bytes, 0x3C)
    $bytes[0x80] = 0x50; $bytes[0x81] = 0x45
    [BitConverter]::GetBytes($Machine).CopyTo($bytes, 0x84)
    [IO.File]::WriteAllBytes($Path, $bytes)
}
function Make-Archive([string]$Name, [scriptblock]$Mutation) {
    $source = Join-Path $work ($Name + '-files')
    New-Item -ItemType Directory -Force -Path (Join-Path $source 'x64') | Out-Null
    New-TestPe (Join-Path $source 'foo_test.dll') ([UInt16]0x014c)
    New-TestPe (Join-Path $source 'x64/foo_test.dll') ([UInt16]0x8664)
    if ($null -ne $Mutation) { & $Mutation $source }
    $archive = Join-Path $work ($Name + '.fb2k-component')
    [IO.Compression.ZipFile]::CreateFromDirectory($source, $archive)
    return $archive
}
function Expect-Rejection([string]$Name, [string]$Archive) {
    $wasRejected = $false
    try { & $verifier -ComponentPath $Archive -DllName 'foo_test.dll' | Out-Null }
    catch { $wasRejected = $true; Write-Host ('PASS expected rejection ' + $Name) }
    if (-not $wasRejected) { throw ('Unexpected acceptance: ' + $Name) }
}
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $valid = Make-Archive 'valid' $null
    $result = & $verifier -ComponentPath $valid -DllName 'foo_test.dll'
    if ($result.Status -ne 'PASS' -or $result.RootMachine -ne '0x014C' -or $result.X64Machine -ne '0x8664') {
        throw 'Valid synthetic Win32/x64 archive failed.'
    }
    $expectedHash = (Get-FileHash -LiteralPath $valid -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($result.Sha256 -ne $expectedHash) { throw 'Synthetic archive hash mismatch.' }
    Write-Host 'PASS valid synthetic Win32/x64 archive'
    Expect-Rejection 'forbidden x86 directory' (Make-Archive 'x86-extra' {
        param($source)
        New-Item -ItemType Directory -Force -Path (Join-Path $source 'x86') | Out-Null
        Copy-Item -LiteralPath (Join-Path $source 'foo_test.dll') -Destination (Join-Path $source 'x86/foo_test.dll')
    })
    Expect-Rejection 'missing x64 DLL' (Make-Archive 'missing-x64' {
        param($source) 
        Remove-Item -LiteralPath (Join-Path $source 'x64/foo_test.dll') -Force
    })
    Expect-Rejection 'wrong Win32 machine' (Make-Archive 'wrong-root' {
        param($source) 
        New-TestPe (Join-Path $source 'foo_test.dll') ([UInt16]0x8664)
    })
    Expect-Rejection 'wrong x64 machine' (Make-Archive 'wrong-x64' {
        param($source)
        New-TestPe (Join-Path $source 'x64/foo_test.dll') ([UInt16]0x014c)
    })
    Expect-Rejection 'corrupt PE' (Make-Archive 'bad-mz' {
        param($source)
        [IO.File]::WriteAllBytes((Join-Path $source 'foo_test.dll'), [byte[]](0,1,2,3))
    })
    $badZip = Join-Path $work 'bad-zip.fb2k-component'
    [IO.File]::WriteAllText($badZip, 'SYNTHETIC_INVALID_ZIP')
    Expect-Rejection 'corrupt ZIP' $badZip
    Write-Host 'PASS public synthetic package verification regression suite'
} finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
#requires -Version 7.2
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateSet('Win32','x64')][string]$Architecture,
  [string]$ComponentDll = '',
  [ValidateRange(10,120)][int]$StartupTimeoutSeconds = 35
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Immutable official-installer pins from microsoft/winget-pkgs:
# manifests/p/PeterPawlowski/foobar2000/2.26.1/...installer.yaml
$specs = @{
  Win32 = @{ Url='https://www.foobar2000.org/files/foobar2000_v2.26.1.exe'; Sha256='849BC4424326DA81049746E9A2255A3A707E56B76CC69ED11714ED23C69ECE52'; Machine=[UInt16]0x014c }
  x64   = @{ Url='https://www.foobar2000.org/files/foobar2000-x64_v2.26.1.exe'; Sha256='72FE15A88B085EE4E49D68114E2BB9655000C2E0FDF40DCC128BBEF8BCAF3600'; Machine=[UInt16]0x8664 }
}
function Get-PeMachine([string]$File) {
  $bytes=[IO.File]::ReadAllBytes($File)
  if ($bytes.Length -lt 512 -or $bytes[0] -ne 77 -or $bytes[1] -ne 90) { throw "Invalid MZ file: $File" }
  $offset=[BitConverter]::ToInt32($bytes,0x3c)
  if ($offset -lt 64 -or $offset -ge ($bytes.Length - 6)) { throw "Invalid PE offset: $File" }
  if ([Text.Encoding]::ASCII.GetString($bytes,$offset,4) -ne ("PE" + [char]0 + [char]0)) { throw "Invalid PE signature: $File" }
  return [BitConverter]::ToUInt16($bytes,$offset+4)
}
function Assert-PeMachine([string]$File,[UInt16]$Expected) {
  if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw "Missing PE file: $File" }
  $actual=Get-PeMachine $File
  if ($actual -ne $Expected) { throw ('Architecture mismatch {0:X4} != {1:X4}: {2}' -f $actual,$Expected,$File) }
}
if ($env:GITHUB_ACTIONS -ne 'true' -or [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
  throw 'Only a disposable GitHub Actions runner is supported.'
}
if (@(Get-Process -Name foobar2000 -ErrorAction SilentlyContinue).Count -gt 0) {
  throw 'Unrelated foobar2000 process exists: refuse non-isolated testing.'
}
$spec=$specs[$Architecture]
if (([uri]$spec.Url).Host -ne 'www.foobar2000.org') { throw 'Invalid official installer origin.' }
$dir=Join-Path $env:RUNNER_TEMP ('fb2k-host-'+$Architecture+'-'+[guid]::NewGuid().ToString('N'))
$target=Join-Path $dir 'host'
$installer=Join-Path $dir 'official-installer.exe'
$proc=$null
try {
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  Invoke-WebRequest -Uri $spec.Url -OutFile $installer -ErrorAction Stop
  $hash=(Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash
  if ($hash -ine $spec.Sha256) { throw "Installer SHA256 mismatch: $Architecture / $hash" }
  # NSIS /D must be the last argument. Runner temp path contains no spaces.
  $result=Start-Process -FilePath $installer -ArgumentList @('/S',"/D=$target") -Wait -PassThru
  if ($result.ExitCode -ne 0) { throw "Installer failed: $($result.ExitCode)" }
  $exe=Join-Path $target 'foobar2000.exe'
  Assert-PeMachine $exe $spec.Machine
  $expected=''
  if ($ComponentDll) {
    $component=(Resolve-Path -LiteralPath $ComponentDll -ErrorAction Stop).Path
    $expected=[IO.Path]::GetFileName($component)
    if ($expected -notmatch '^foo_[A-Za-z0-9_.-]+\.dll$') { throw "Unexpected component DLL name: $expected" }
    Assert-PeMachine $component $spec.Machine
    $components=Join-Path $target 'components'
    New-Item -ItemType Directory -Force -Path $components | Out-Null
    Copy-Item -LiteralPath $component -Destination (Join-Path $components $expected) -ErrorAction Stop
  }
  # Make the player profile disposable as well. Never access the real user's music.
  New-Item -ItemType File -Force -Path (Join-Path $target 'portable_mode_enabled') | Out-Null
  $proc=Start-Process -FilePath $exe -WorkingDirectory $target -PassThru
  $start=[DateTime]::UtcNow
  $deadline=$start.AddSeconds($StartupTimeoutSeconds)
  $loaded=$false
  while ([DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 750
    $proc.Refresh()
    if ($proc.HasExited) { throw "foobar2000 $Architecture exited at startup ($($proc.ExitCode))" }
    if (-not $expected) {
      if (([DateTime]::UtcNow - $start).TotalSeconds -gt 4) { break }
      continue
    }
    try {
      $modules=@((Get-Process -Id $proc.Id -ErrorAction Stop).Modules)
      $loaded=@($modules | Where-Object {
        $_.ModuleName -ieq $expected -and
        $_.FileName.StartsWith($target,[StringComparison]::OrdinalIgnoreCase)
      }).Count -gt 0
    } catch [System.ComponentModel.Win32Exception] { }
    if ($loaded) { break }
  }
  if (-not $expected -and $proc.HasExited) { throw "foobar2000 $Architecture did not stay running." }
  if ($expected -and -not $loaded) { throw "COMPONENT_LOAD_$Architecture=FAIL ($expected absent in process modules)" }
  Write-Host "HOST_BOOT_$Architecture=PASS"
  if ($expected) { Write-Host "COMPONENT_LOAD_$Architecture=PASS" }
  else { Write-Host "COMPONENT_LOAD_$Architecture=NOT_TESTED" }
  Write-Host "FOOBAR_UI_$Architecture=NOT_TESTED"
  Write-Host "MEDIA_WRITE_SAFETY_$Architecture=NOT_TESTED"
} finally {
  if ($null -ne $proc) {
    try { if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } }
    catch { Write-Warning 'Could not stop disposable foobar process.' }
  }
  if (Test-Path -LiteralPath $dir) {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

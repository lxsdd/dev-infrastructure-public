#requires -Version 7.2
Set-StrictMode -Version Latest

# Job-local, content-addressed transport cache. It never leaves RUNNER_TEMP.
# Each actual foobar host still gets a new independent disposable profile.
function Get-FoobarPinnedInstaller {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][ValidateSet('Win32','x64')][string]$Architecture,
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$Sha256,
    [Parameter(Mandatory)][string]$CacheRoot,
    [scriptblock]$DownloadAction = {
      param([string]$OfficialUrl,[string]$Destination)
      Invoke-WebRequest -Uri $OfficialUrl -OutFile $Destination -ErrorAction Stop
    }
  )
  $expectedName = if ($Architecture -ceq 'x64') {
    "foobar2000-x64_v$Version.exe"
  } else {
    "foobar2000_v$Version.exe"
  }
  $uri = [uri]$Url
  if ($uri.Scheme -cne 'https' -or $uri.Host -cne 'www.foobar2000.org' -or
      $uri.Port -ne 443 -or $uri.AbsolutePath -cne "/files/$expectedName" -or
      -not [string]::IsNullOrEmpty($uri.Query) -or
      -not [string]::IsNullOrEmpty($uri.Fragment)) {
    throw 'Pinned foobar installer must use the matching official HTTPS URL and architecture.'
  }
  if ($Version -notmatch '^\d+\.\d+(\.\d+)?$') { throw 'Invalid pinned foobar version.' }
  if (-not (Test-Path -LiteralPath $CacheRoot -PathType Container)) {
    throw 'Job-local runner cache root does not exist.'
  }
  $sha=$Sha256.ToLowerInvariant()
  $folder=Join-Path $CacheRoot 'foobar2000-verified-installer-v1'
  New-Item -ItemType Directory -Path $folder -Force | Out-Null
  $cached=Join-Path $folder ("$Architecture-$Version-$sha.exe")
  function Assert-PinnedInstaller([string]$candidate,[string]$expected) {
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      throw 'Pinned foobar installer file is missing.'
    }
    $actual=(Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne $expected) {
      throw "Pinned foobar installer SHA256 mismatch; refusing cached or downloaded bytes: $actual"
    }
  }
  if (Test-Path -LiteralPath $cached) {
    Assert-PinnedInstaller $cached $sha
    Write-Host "FOOBAR_INSTALLER_CACHE_HIT=$Architecture version=$Version verified_sha256=$sha"
    return $cached
  }
  $partial=Join-Path $folder ('.download-'+[guid]::NewGuid().ToString('N')+'.partial')
  try {
    # Download only when no verified job-local copy exists. Never publish it as
    # an Actions cache/artifact; no alternate host or unpinned binary is used.
    try {
      & $DownloadAction $Url $partial
    } catch {
      # Infrastructure unavailability must not be reported as a component
      # regression. Fail the required host gate, explicitly unqualified.
      $reason=$_.Exception.GetType().Name
      throw "HOST_DEPENDENCY_TRANSPORT_BLOCKED: official foobar2000 $Version $Architecture unavailable ($reason); HOST_BOOT, COMPONENT_LOAD, GUI and writer gates NOT_TESTED."
    }
    Assert-PinnedInstaller $partial $sha
    if (Test-Path -LiteralPath $cached) {
      Assert-PinnedInstaller $cached $sha
    } else {
      Move-Item -LiteralPath $partial -Destination $cached -ErrorAction Stop
      Assert-PinnedInstaller $cached $sha
    }
    Write-Host "FOOBAR_INSTALLER_CACHE_MISS=$Architecture version=$Version verified_sha256=$sha"
    return $cached
  } finally {
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
  }
}

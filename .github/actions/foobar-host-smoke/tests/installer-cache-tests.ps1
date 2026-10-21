$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../pinned-installer-cache.ps1')

$base=Join-Path $env:RUNNER_TEMP ('fb2k-cache-fixture-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $base | Out-Null
$script:cacheFixtureBytes=[Text.Encoding]::ASCII.GetBytes('Synthetic fixture, NOT a foobar binary')
$script:cacheFetchCount=0
$mockDownload={
  param($url,$destination)
  $script:cacheFetchCount++
  [IO.File]::WriteAllBytes($destination,$script:cacheFixtureBytes)
}
$sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($script:cacheFixtureBytes))
$winUrl='https://www.foobar2000.org/files/foobar2000_v2.26.1.exe'
$x64Url='https://www.foobar2000.org/files/foobar2000-x64_v2.26.1.exe'
try {
  $first=Get-FoobarPinnedInstaller -Architecture Win32 -Version '2.26.1' -Url $winUrl `
    -Sha256 $sha -CacheRoot $base -DownloadAction $mockDownload
  $again=Get-FoobarPinnedInstaller -Architecture Win32 -Version '2.26.1' -Url $winUrl `
    -Sha256 $sha -CacheRoot $base -DownloadAction $mockDownload
  if ($script:cacheFetchCount -ne 1 -or $first -cne $again) {
    throw 'Cache re-downloads the same checked input'
  }
  if (-not ($first.StartsWith($base,[StringComparison]::OrdinalIgnoreCase))) {
    throw 'Cache path escaped the runner temp directory'
  }
  Write-Host 'PASS: unchanged exact Win32 version/sha uses ONE fetch within job'

  # Each architecture has its own independently verified cache entry.
  $other=Get-FoobarPinnedInstaller -Architecture x64 -Version '2.26.1' -Url $x64Url `
    -Sha256 $sha -CacheRoot $base -DownloadAction $mockDownload
  if ($other -ceq $first -or $script:cacheFetchCount -ne 2) {
    throw 'Architecture-specific cache isolation failed'
  }
  Write-Host 'PASS: Win32 and x64 have distinct version-locked cache paths'

  # An unexpected content change is fatal: never quietly overwrite/re-fetch.
  [IO.File]::WriteAllBytes($first,[Text.Encoding]::ASCII.GetBytes('Tampered bytes'))
  $denied=$false
  try {
    Get-FoobarPinnedInstaller -Architecture Win32 -Version '2.26.1' -Url $winUrl `
      -Sha256 $sha -CacheRoot $base -DownloadAction $mockDownload | Out-Null
  } catch { $denied=$true }
  if (-not $denied -or $script:cacheFetchCount -ne 2) {
    throw 'Tampered job-local cache was accepted or silently downloaded again'
  }
  Write-Host 'PASS: cache poisoning fails closed without refetching'

  $denied=$false
  try {
    Get-FoobarPinnedInstaller -Architecture Win32 -Version '2.26.2' -Url $winUrl `
      -Sha256 $sha -CacheRoot $base -DownloadAction $mockDownload | Out-Null
  } catch { $denied=$true }
  if (-not $denied -or $script:cacheFetchCount -ne 2) {
    throw 'Wrong vendor version was not rejected'
  }
  $denied=$false
  try {
    Get-FoobarPinnedInstaller -Architecture Win32 -Version '2.26.1' `
      -Url 'https://untrusted.example/files/foobar2000_v2.26.1.exe' `
      -Sha256 $sha -CacheRoot $base -DownloadAction $mockDownload | Out-Null
  } catch { $denied=$true }
  if (-not $denied -or $script:cacheFetchCount -ne 2) {
    throw 'Non-official installer URL was accepted'
  }
  Write-Host 'PASS: pinned version and vendor host checks reject mismatches'

  $badRoot=Join-Path $base 'bad-digest'
  New-Item -ItemType Directory -Force -Path $badRoot | Out-Null
  $denied=$false
  try {
    Get-FoobarPinnedInstaller -Architecture Win32 -Version '2.26.1' -Url $winUrl `
      -Sha256 ('0'*64) -CacheRoot $badRoot -DownloadAction $mockDownload | Out-Null
  } catch { $denied=$true }
  if (-not $denied -or @(Get-ChildItem $badRoot -File -Recurse).Count -ne 0) {
    throw 'Unpinned download or partial file survived hash failure'
  }
  $interrupted=Join-Path $base 'interrupted'
  New-Item -ItemType Directory -Force -Path $interrupted | Out-Null
  $abortDownload={
    param($url,$destination)
    [IO.File]::WriteAllBytes($destination,[byte[]](1,2,3))
    throw 'Simulated interrupted transport'
  }
  $denied=$false
  try {
    Get-FoobarPinnedInstaller -Architecture x64 -Version '2.26.1' -Url $x64Url `
      -Sha256 $sha -CacheRoot $interrupted -DownloadAction $abortDownload | Out-Null
  } catch {
    $denied=$true
    if ($_.Exception.Message -notmatch 'HOST_DEPENDENCY_TRANSPORT_BLOCKED.*NOT_TESTED') {
      throw 'Transport error did not classify the host gate as untested'
    }
  }
  if (-not $denied -or @(Get-ChildItem $interrupted -File -Recurse).Count -ne 0) {
    throw 'Partial network download poisoned future cache'
  }
  Write-Host 'PASS: bad SHA and interrupted transport remove all partial files'
} finally {
  Remove-Item -LiteralPath $base -Force -Recurse -ErrorAction SilentlyContinue
}

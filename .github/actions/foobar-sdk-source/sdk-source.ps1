#requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$SdkRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

# This is a verified SDK SOURCE tree, not a downloaded .7z archive.
# Never claim an archive SHA256 when the source arrives through Git.
$Version='2026-10-01'
$Repo='https://github.com/lxsdd/foobar2000_component_template.git'
$PinnedCommit='31a35947a7527826c2199491692802e3ce3d8bd7'
$PinnedTree='2ba8caeb73f72633ad7f60ee5f72ed8074a0eb17'
$PinnedArchiveSha256='d4c55077336fae81bf8df0259b5b2748fa45ea84132c656ead93eb123cbcdc26'
$PinnedArchiveSize=793738L
$OfficialUrl='https://www.foobar2000.org/downloads/SDK-2026-10-01.7z'
if ($env:GITHUB_ACTIONS -ne 'true' -or [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
  throw 'Only disposable GitHub Actions runners may use this source bootstrap.'
}
$root=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
$target=[IO.Path]::GetFullPath($SdkRoot)
if (-not $target.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)) {
  throw 'SDK destination must remain inside the disposable runner temp directory.'
}
if (Test-Path -LiteralPath $target) {
  throw 'SDK target already exists; refusing to replace unchecked bytes.'
}
$git=(Get-Command 'git.exe' -ErrorAction Stop).Source
$checkout=Join-Path $root ('sdk-verified-source-'+[guid]::NewGuid().ToString('N'))
$staging=Join-Path $root ('sdk-staging-'+[guid]::NewGuid().ToString('N'))
try {
  & $git clone --quiet --no-checkout --filter=blob:none $Repo $checkout
  if ($LASTEXITCODE -ne 0) { throw 'Owner SDK source clone failed.' }
  & $git -C $checkout checkout --quiet --detach $PinnedCommit
  if ($LASTEXITCODE -ne 0) { throw 'Pinned owner SDK commit checkout failed.' }
  $actualCommit=(& $git -C $checkout rev-parse HEAD).Trim()
  $actualTree=(& $git -C $checkout rev-parse 'HEAD:vendor/sdk').Trim()
  if ($LASTEXITCODE -ne 0 -or $actualCommit -cne $PinnedCommit -or
      $actualTree -cne $PinnedTree) {
    throw 'Pinned owner SDK source commit/tree mismatch.'
  }
  $manifest=Get-Content -LiteralPath (Join-Path $checkout 'SDK-PIN.json') -Raw |
    ConvertFrom-Json
  if ($manifest.sdk_version -cne $Version -or
      $manifest.upstream_url -cne $OfficialUrl -or
      $manifest.upstream_archive_sha256 -cne $PinnedArchiveSha256 -or
      [int64]$manifest.archive_size_bytes -ne $PinnedArchiveSize) {
    throw 'Git SDK manifest does not match exact independently verified upstream pins.'
  }
  $vendor=Join-Path $checkout 'vendor/sdk'
  foreach ($relative in @(
    'sdk-license.txt', 'sdk-readme.html', 'foobar2000/SDK/foobar2000.h',
    'foobar2000/SDK/foobar2000_SDK.vcxproj',
    'foobar2000/helpers/foobar2000_sdk_helpers.vcxproj',
    'foobar2000/foobar2000_component_client/foobar2000_component_client.vcxproj',
    'foobar2000/shared/shared.vcxproj',
    'foobar2000/shared/shared-Win32.lib',
    'foobar2000/shared/shared-x64.lib',
    'pfc/pfc.vcxproj', 'libPPUI/libPPUI.vcxproj'
  )) {
    if (-not (Test-Path -LiteralPath (Join-Path $vendor $relative) -PathType Leaf)) {
      throw "Pinned SDK tree lacks required source/linker input: $relative"
    }
  }
  if (-not (Get-Content -LiteralPath (Join-Path $vendor 'sdk-readme.html') -Raw).
      Contains("foobar2000 SDK, version $Version")) {
    throw 'Owner SDK source readme has an incorrect version.'
  }
  if (-not (Get-Content -LiteralPath (Join-Path $vendor 'sdk-license.txt') -Raw).
      Contains('Redistribution and use in source and binary forms')) {
    throw 'Owner SDK source lacks its expected redistribution notice.'
  }
  New-Item -ItemType Directory -Path $staging -Force | Out-Null
  Copy-Item -Path (Join-Path $vendor '*') -Destination $staging -Recurse -Force
  Move-Item -LiteralPath $staging -Destination $target -ErrorAction Stop
  Write-Host "FOOBAR_SDK_SOURCE_GIT_TREE_VERIFIED=PASS version=$Version commit=$PinnedCommit tree=$PinnedTree"
  Write-Host 'FOOBAR_SDK_ORIGINAL_ARCHIVE_SHA256=NOT_TESTED_BY_THIS_RUN'
  Write-Host 'FOOBAR_SDK_HOST_RUNTIME=NOT_TESTED'
} finally {
  Remove-Item -LiteralPath $checkout -Force -Recurse -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $staging -Force -Recurse -ErrorAction SilentlyContinue
}

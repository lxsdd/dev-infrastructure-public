$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../synthetic-wave.ps1')
. (Join-Path $PSScriptRoot '../synthetic-cue.ps1')
$base=Join-Path $env:RUNNER_TEMP ('fb2k-cue-fixture-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $base | Out-Null
try {
  $wav=Join-Path $base 'synthetic-8k-silence.wav'
  $cue=Join-Path $base 'synthetic-dual.cue'
  $wavBefore=New-FoobarSyntheticWave -Path $wav
  $cueBefore=New-FoobarSyntheticCue -Path $cue
  $source=[IO.File]::ReadAllText($cue,[Text.Encoding]::ASCII)
  if ($source -notmatch 'FILE "synthetic-8k-silence.wav" WAVE' -or
      $source -notmatch 'TRACK 01 AUDIO' -or
      $source -notmatch 'TRACK 02 AUDIO') {
    throw 'Relative audio reference and both cue tracks are required'
  }
  Assert-FoobarFixtureUnchanged -Path $wav -Before $wavBefore
  Assert-FoobarFixtureUnchanged -Path $cue -Before $cueBefore
  $rejected=$false
  try { New-FoobarSyntheticCue -Path $cue | Out-Null } catch { $rejected=$true }
  if (-not $rejected) { throw 'CUE overwrite protection missing' }
  $bytes=[IO.File]::ReadAllBytes($cue)
  $bytes[0]=65
  [IO.File]::WriteAllBytes($cue,$bytes)
  $rejected=$false
  try { Assert-FoobarFixtureUnchanged -Path $cue -Before $cueBefore } catch { $rejected=$true }
  if (-not $rejected) { throw 'CUE corruption not detected' }
  Write-Host 'PASS: synthetic external CUE and fail-closed negative integrity checks'
} finally {
  Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}

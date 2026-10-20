$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../synthetic-wave.ps1')
$base=Join-Path $env:RUNNER_TEMP ('fb2k-fixture-unit-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $base | Out-Null
try {
  $path=Join-Path $base 'synthetic.wav'
  $before=New-FoobarSyntheticWave -Path $path
  if ($before.Length -ne 16044) { throw 'Incorrect WAVE fixture size' }
  Assert-FoobarFixtureUnchanged -Path $path -Before $before
  $rejected=$false
  try { New-FoobarSyntheticWave -Path $path | Out-Null } catch { $rejected=$true }
  if (-not $rejected) { throw 'Generator allowed overwriting a file' }
  Assert-FoobarFixtureUnchanged -Path $path -Before $before

  $item=Get-Item -LiteralPath $path
  $item.LastWriteTimeUtc=$item.LastWriteTimeUtc.AddSeconds(3)
  $rejected=$false
  try { Assert-FoobarFixtureUnchanged -Path $path -Before $before } catch { $rejected=$true }
  if (-not $rejected) { throw 'Timestamp mutation undetected' }

  $bytes=[IO.File]::ReadAllBytes($path)
  $bytes[44]=1
  [IO.File]::WriteAllBytes($path,$bytes)
  $rejected=$false
  try { Assert-FoobarFixtureUnchanged -Path $path -Before $before } catch { $rejected=$true }
  if (-not $rejected) { throw 'Content mutation undetected' }
  Write-Host 'PASS: synthetic WAVE fixture generation, overwrite and mutation guards'
} finally {
  Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}

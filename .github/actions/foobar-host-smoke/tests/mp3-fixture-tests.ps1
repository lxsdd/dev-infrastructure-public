#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\synthetic-wave.ps1')
. (Join-Path $PSScriptRoot '..\synthetic-mp3.ps1')
$dir=Join-Path $env:RUNNER_TEMP ('synthetic-mp3-contract-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $dir | Out-Null
try {
  $path=Join-Path $dir 'silent-synthetic.mp3'
  $before=New-FoobarSyntheticMp3 -Path $path
  if($before.Length -ne 3553 -or
     $before.Sha256 -ine '81F0EF1A0F124C413648C525D7118E4F3D8F8051C6724C7FF74AC6BDB5E3D114') {
    throw 'Synthetic MP3 checksum or length regression'
  }
  $raw=[IO.File]::ReadAllBytes($path)
  if($raw[0] -ne 255 -or $raw[1] -ne 251) { throw 'MP3 frame header missing' }
  Assert-FoobarFixtureUnchanged -Path $path -Before $before
  $rejected=$false
  try { $null=New-FoobarSyntheticMp3 -Path $path }
  catch { $rejected=$true }
  if(-not $rejected) { throw 'Synthetic MP3 fixture overwrote an existing file' }
  [IO.File]::AppendAllText($path,'changed')
  $rejected=$false
  try { Assert-FoobarFixtureUnchanged -Path $path -Before $before }
  catch { $rejected=$true }
  if(-not $rejected) { throw 'Synthetic MP3 fixture did not detect source mutation' }
  Write-Host 'SYNTHETIC_MP3_CREATE_ONLY_AND_IMMUTABILITY=PASS'
} finally {
  if(Test-Path -LiteralPath $dir) {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

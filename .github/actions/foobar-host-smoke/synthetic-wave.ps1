# Only deterministic synthetic files. No host, network, or tag writer calls.
Set-StrictMode -Version Latest

function Get-FoobarFixtureSnapshot {
  param([Parameter(Mandatory)][string]$Path)
  $item=Get-Item -LiteralPath $Path -ErrorAction Stop
  if ($item.PSIsContainer) { throw 'Expected a regular file' }
  return [pscustomobject]@{
    Sha256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    Length=$item.Length
    LastWriteUtcTicks=$item.LastWriteTimeUtc.Ticks
  }
}

function New-FoobarSyntheticWave {
  param([Parameter(Mandatory)][string]$Path)
  if (Test-Path -LiteralPath $Path) { throw "Existing fixture may not be overwritten: $Path" }
  [byte[]]$payload=[byte[]]::new(16000)
  $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  $writer=[IO.BinaryWriter]::new($stream,[Text.Encoding]::ASCII)
  try {
    $writer.Write([Text.Encoding]::ASCII.GetBytes("RIFF"))
    $writer.Write([int](36+$payload.Length))
    $writer.Write([Text.Encoding]::ASCII.GetBytes("WAVE"))
    $writer.Write([Text.Encoding]::ASCII.GetBytes("fmt "))
    $writer.Write([int]16)
    $writer.Write([UInt16]1)
    $writer.Write([UInt16]1)
    $writer.Write([int]8000)
    $writer.Write([int]16000)
    $writer.Write([UInt16]2)
    $writer.Write([UInt16]16)
    $writer.Write([Text.Encoding]::ASCII.GetBytes("data"))
    $writer.Write([int]$payload.Length)
    $writer.Write($payload)
    $writer.Flush()
  } finally {
    $writer.Dispose()
    $stream.Dispose()
  }
  [byte[]]$bytes=[IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -ne 16044 -or
      [Text.Encoding]::ASCII.GetString($bytes,0,4) -ne 'RIFF' -or
      [Text.Encoding]::ASCII.GetString($bytes,8,4) -ne 'WAVE' -or
      [Text.Encoding]::ASCII.GetString($bytes,36,4) -ne 'data') {
    throw 'Unexpected synthetic 8kHz mono 16-bit PCM WAVE header or size'
  }
  return Get-FoobarFixtureSnapshot -Path $Path
}

function Assert-FoobarFixtureUnchanged {
  param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Before)
  $after=Get-FoobarFixtureSnapshot -Path $Path
  if ($after.Sha256 -cne $Before.Sha256 -or
      $after.Length -ne $Before.Length -or
      $after.LastWriteUtcTicks -ne $Before.LastWriteUtcTicks) {
    throw 'SYNTHETIC_WAV_NO_WRITE=FAIL: bytes, size, or timestamp changed'
  }
}

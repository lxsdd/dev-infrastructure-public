# Pure synthetic external CUE creation: never changes an existing file.
Set-StrictMode -Version Latest
function New-FoobarSyntheticCue {
  param([Parameter(Mandatory)][string]$Path)
  if (Test-Path -LiteralPath $Path) {
    throw "Existing CUE file must not be overwritten: $Path"
  }
  $lines=@(
    'PERFORMER "Synthetic Test Artist"',
    'TITLE "Disposable Test Album"',
    'FILE "synthetic-8k-silence.wav" WAVE',
    '  TRACK 01 AUDIO',
    '    TITLE "Fixture Part One"',
    '    INDEX 01 00:00:00',
    '  TRACK 02 AUDIO',
    '    TITLE "Fixture Part Two"',
    '    INDEX 01 00:00:40'
  )
  $crlf=[string][char]13 + [string][char]10
  $content=($lines -join $crlf) + $crlf
  $bytes=[Text.Encoding]::ASCII.GetBytes($content)
  $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  try {
    $stream.Write($bytes,0,$bytes.Length)
    $stream.Flush()
  } finally {
    $stream.Dispose()
  }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Failed to create synthetic CUE' }
  if ($content -notmatch 'TRACK 02 AUDIO' -or $content -notmatch 'INDEX 01 00:00:40') {
    throw 'Invalid synthetic two-track CUE fixture'
  }
  return Get-FoobarFixtureSnapshot -Path $Path
}

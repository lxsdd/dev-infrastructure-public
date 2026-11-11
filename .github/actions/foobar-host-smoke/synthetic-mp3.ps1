# Deterministic 0.888 s MPEG-1 Layer III mono silence, 44.1 kHz / 32 kbps.
# Reconstructed from a locally generated ffmpeg/libmp3lame pure-silence fixture.
# No copyrighted media, network, encoder installation or users' files required.
# SHA256 is immutable; create-only within a disposable runner directory.
Set-StrictMode -Version Latest

function New-FoobarSyntheticMp3 {
  param([Parameter(Mandatory)][string]$Path)
  if (Test-Path -LiteralPath $Path) { throw "Existing fixture may not be overwritten: $Path" }
  [byte[]]$common=[Convert]::FromHexString('c00001a40000002000003480000004')
  [byte[]]$p4=@(0,41,83,125,167,208,214,213)
  [byte[]]$p5=@(3,131,131,3,3,131,3,131)
  [byte[]]$lame=[Text.Encoding]::ASCII.GetBytes('LAME3.100')
  [byte[]]$result=[byte[]]::new(3553)
  $offset=0
  for($i=0;$i -lt 34;$i++) {
    $odd=($i % 2)
    $length=104+$odd
    [byte[]]$frame=[byte[]]::new($length)
    for($j=0;$j -lt $length;$j++) { $frame[$j]=85 }
    $slot=$i
    if($i -ge 8) { $slot=6+$odd }
    $frame[0]=255
    $frame[1]=251
    if($odd) { $frame[2]=18 } else { $frame[2]=16 }
    $frame[3]=196
    $frame[4]=$p4[$slot]
    $frame[5]=$p5[$slot]
    [Array]::Copy($common,0,$frame,6,$common.Length)
    if($i -eq 0) { [Array]::Copy($lame,0,$frame,21,$lame.Length) }
    if($i -lt 28) { [Array]::Copy($lame,0,$frame,$length-10,$lame.Length) }
    [Array]::Copy($frame,0,$result,$offset,$length)
    $offset+=$length
  }
  if($offset -ne $result.Length) { throw 'Synthetic MP3 length mismatch' }
  $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($result))
  $expected='81F0EF1A0F124C413648C525D7118E4F3D8F8051C6724C7FF74AC6BDB5E3D114'
  if($hash -cne $expected) { throw "Synthetic MP3 checksum mismatch: $hash" }
  $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  try { $stream.Write($result,0,$result.Length) } finally { $stream.Dispose() }
  return Get-FoobarFixtureSnapshot -Path $Path
}

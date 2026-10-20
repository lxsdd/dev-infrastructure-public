#requires -Version 7.2
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateSet('Win32','x64')][string]$Architecture,
  [string]$ComponentDll = '',
  [string]$ContextCommand = '',
  [string]$ExpectedWindowTitle = '',
  [string]$RequiredControlIds = '',
  [string]$OfflineClipboardTest = '',
  [int]$ClipboardButtonId = 0,
  [int]$ClipboardListId = 0,
  [bool]$BeatportEditionProbe = $false,
  [bool]$StalePhysicalProbe = $false,
  [ValidateRange(10,120)][int]$StartupTimeoutSeconds = 35
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'synthetic-wave.ps1')

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

if($ContextCommand) {
  if(-not $ComponentDll -or -not $ExpectedWindowTitle -or
     $ContextCommand.Length -gt 140 -or $ExpectedWindowTitle.Length -gt 180 -or
     $ContextCommand -notmatch '^[a-zA-Z0-9 ()/._-]+$' -or
     $ExpectedWindowTitle -notmatch '^[a-zA-Z0-9 ()/._-]+$') {
    throw 'Invalid synthetic context workspace probe.'
  }
  Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class FoobarHostWindow {
  delegate bool Callback(IntPtr h,IntPtr p);
  [DllImport("user32.dll")] static extern bool EnumWindows(Callback f,IntPtr p);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h,StringBuilder b,int cap);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr h,int id);
  [DllImport("user32.dll")] static extern IntPtr SendMessageTimeoutW(IntPtr h,uint m,IntPtr w,IntPtr l,uint flags,uint timeout,out IntPtr result);
  public static IntPtr[] Find(uint pid,string title) {
    var windows=new System.Collections.Generic.List<IntPtr>();
    EnumWindows((h,p)=>{
      uint owner; GetWindowThreadProcessId(h,out owner);
      if(owner!=pid || !IsWindowVisible(h)) return true;
      var b=new StringBuilder(256);GetWindowTextW(h,b,256);
      if(b.ToString()==title) windows.Add(h);
      return true;
    },IntPtr.Zero);
    return windows.ToArray();
  }
  [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr h);
  public static bool Click(IntPtr dialog,int id) {
    var control=GetDlgItem(dialog,id);
    if(control==IntPtr.Zero || !IsWindowEnabled(control) || !IsWindowVisible(control)) return false;
    IntPtr result;
    return SendMessageTimeoutW(control,0x00F5,IntPtr.Zero,IntPtr.Zero,2,8000,out result)!=IntPtr.Zero;
  }
  public static int ListCount(IntPtr dialog,int id) {
    var list=GetDlgItem(dialog,id);
    if(list==IntPtr.Zero) throw new InvalidOperationException("Missing native result list.");
    IntPtr count;
    if(SendMessageTimeoutW(list,0x1004,IntPtr.Zero,IntPtr.Zero,2,5000,out count)==IntPtr.Zero)
      throw new InvalidOperationException("Native candidate ListView did not respond.");
    return checked((int)count.ToInt64());
  }
  public static bool Enabled(IntPtr dialog,int id) {
    var control=GetDlgItem(dialog,id);
    return control!=IntPtr.Zero && IsWindowEnabled(control);
  }
  public static string Text(IntPtr hwnd,int id) {
    var control=id==0?hwnd:GetDlgItem(hwnd,id);
    if(control==IntPtr.Zero) return "";
    var text=new StringBuilder(1024);
    GetWindowTextW(control,text,text.Capacity);
    return text.ToString();
  }
  public static string[] Describe(uint pid) {
    var windows=new System.Collections.Generic.List<string>();
    EnumWindows((h,p)=>{
      uint owner; GetWindowThreadProcessId(h,out owner);
      if(owner!=pid) return true;
      var b=new StringBuilder(256);GetWindowTextW(h,b,256);
      windows.Add("visible="+IsWindowVisible(h)+" title="+b.ToString());
      return true;
    },IntPtr.Zero);
    return windows.ToArray();
  }
  public static bool Responsive(IntPtr h) {
    IntPtr value;
    return SendMessageTimeoutW(h,0,IntPtr.Zero,IntPtr.Zero,2,3000,out value)!=IntPtr.Zero;
  }
}
'@
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
  # Append only a new synthetic WAV in runner temp; do not start playback.
  $fixture=Join-Path $dir 'synthetic-8k-silence.wav'
  $fixtureBefore=New-FoobarSyntheticWave -Path $fixture
  $dispatch=$null
  try {
    $dispatch=Start-Process -FilePath $exe -WorkingDirectory $target -ArgumentList @('/add','/immediate',$fixture) -PassThru
    if (-not $dispatch.WaitForExit(15000)) { throw "foobar2000 $Architecture did not return from /add" }
    if ($dispatch.ExitCode -ne 0) { throw "foobar2000 $Architecture /add exited $($dispatch.ExitCode)" }
    Start-Sleep -Seconds 2
    $proc.Refresh()
    if ($proc.HasExited) { throw "foobar2000 $Architecture exited after /add" }
    Assert-FoobarFixtureUnchanged -Path $fixture -Before $fixtureBefore
    Write-Host "SYNTHETIC_WAV_CLI_NO_WRITE_$Architecture=PASS"
  } finally {
    if ($null -ne $dispatch) {
      try { if (-not $dispatch.HasExited) { Stop-Process -Id $dispatch.Id -Force -ErrorAction Stop } }
      catch { Write-Warning 'Could not stop disposable /add launcher.' }
    }
  }
  Write-Host "HOST_BOOT_$Architecture=PASS"
  if ($expected) { Write-Host "COMPONENT_LOAD_$Architecture=PASS" }
  else { Write-Host "COMPONENT_LOAD_$Architecture=NOT_TESTED" }

  if ($ContextCommand) {
    $controls=@()
    if ($RequiredControlIds) {
      foreach($item in $RequiredControlIds.Split(',')) {
        $id=0
        if(-not [int]::TryParse($item.Trim(),[ref]$id) -or $id -lt 1 -or $id -gt 65535) {
          throw 'Invalid native control ID.'
        }
        $controls+= $id
      }
    }
    # /context_command addresses this specific disposable file, never the user's library.
    $arg='/context_command:"'+$ContextCommand+'" "'+$fixture+'"'
    $forward=$null
    try {
      $forward=Start-Process -FilePath $exe -WorkingDirectory $target -ArgumentList $arg -PassThru
      if (-not $forward.WaitForExit(15000) -or $forward.ExitCode -ne 0) {
        throw 'The foobar context command launcher did not complete.'
      }
    } finally {
      if ($null -ne $forward -and -not $forward.HasExited) { Stop-Process -Id $forward.Id -Force }
    }
    $window=[IntPtr]::Zero
    for($i=0;$i -lt 16;$i++) {
      Start-Sleep -Milliseconds 500
      $proc.Refresh()
      if($proc.HasExited) { throw 'Host exited while opening the workspace.' }
      $found=[FoobarHostWindow]::Find([uint32]$proc.Id,$ExpectedWindowTitle)
      if($found.Length -gt 1) { throw 'Duplicate native workspace.' }
      if($found.Length -eq 1) { $window=$found[0]; break }
    }
    if($window -eq [IntPtr]::Zero) {
      # foobar may address context commands by their leaf name rather than
      # the prefixed Preferences > Context Menu group path. Do not guess a
      # new provider, file, token or write action: retry only the same leaf.
      $leaf=($ContextCommand -split '/')[-1]
      if($leaf -ne $ContextCommand) {
        Write-Host 'HOST_CONTEXT_ROUTE=RETRY_LEAF_NAME'
        $arg='/context_command:"'+$leaf+'" "'+$fixture+'"'
        $fallback=Start-Process -FilePath $exe -WorkingDirectory $target -ArgumentList $arg -PassThru
        if(-not $fallback.WaitForExit(15000) -or $fallback.ExitCode -ne 0) {
          throw 'Leaf context launcher refused the synthetic fixture.'
        }
        for($i=0;$i -lt 24;$i++) {
          Start-Sleep -Milliseconds 500
          $found=[FoobarHostWindow]::Find([uint32]$proc.Id,$ExpectedWindowTitle)
          if($found.Length -gt 1) { throw 'Duplicate workspace after leaf command.' }
          if($found.Length -eq 1) { $window=$found[0];break }
        }
      }
    }
    if($window -eq [IntPtr]::Zero) {
      foreach($item in [FoobarHostWindow]::Describe([uint32]$proc.Id)) {
        Write-Host "HOST_WINDOW_DIAGNOSTIC=$item"
      }
      throw 'Real foobar context command did not open Studio (full path and leaf tested).'
    }
    if(-not [FoobarHostWindow]::Responsive($window)) { throw 'Studio window unresponsive.' }
    foreach($id in $controls) {
      if([FoobarHostWindow]::GetDlgItem($window,$id) -eq [IntPtr]::Zero) {
        throw "Studio missing control $id."
      }
    }
    Write-Host "HOST_WORKSPACE_OPEN_$Architecture=PASS"
    Write-Host "HOST_WORKSPACE_CONTROLS_$Architecture=PASS"
    if($OfflineClipboardTest) {
      # No provider call. Synthetic user-declared metadata only.
      if($OfflineClipboardTest.Length -gt 2048 -or
         $OfflineClipboardTest -notmatch '(?m)^@provider=discogs\r?$' -or
         $OfflineClipboardTest -notmatch '(?m)^@id=release:[0-9]+\r?$' -or
         $OfflineClipboardTest -notmatch '(?m)^GENRE=[A-Za-z0-9 -]{1,50}\r?$' -or
         $ClipboardButtonId -lt 1 -or $ClipboardListId -lt 1) {
        throw 'Offline clipboard probe accepts only a bounded synthetic declared candidate.'
      }
      $prior=[FoobarHostWindow]::ListCount($window,$ClipboardListId)
      try {
        Set-Clipboard -Value $OfflineClipboardTest -ErrorAction Stop
        if(-not [FoobarHostWindow]::Click($window,$ClipboardButtonId)) {
          throw 'Native Import clipboard control did not accept activation.'
        }
        $after=[FoobarHostWindow]::ListCount($window,$ClipboardListId)
        if($after -lt 2 -or $after -le $prior) {
          throw "Native offline candidate fields not populated ($prior to $after)."
        }
        Write-Host "HOST_OFFLINE_FIELD_COMPARE_$Architecture=PASS (declared synthetic provenance, read-only)"
      } finally {
        Set-Clipboard -Value '' -ErrorAction SilentlyContinue
      }
    }
    if($BeatportEditionProbe) {
      if(-not $OfflineClipboardTest -or $ClipboardButtonId -le 0 -or $ClipboardListId -le 0) {
        throw 'Beatport probe requires qualified earlier synthetic clipboard import.'
      }
      # Completely fabricated, user-declared offline edition: not official API.
      # Two independent recording IDs, distinct mix versions and one exact
      # edition ID. The synthetic 1s WAV does NOT match either recording;
      # the native field list must therefore remain evidence-only.
      $beatport=@'
@beatport-release-json
{"id":987,"name":"Runner EP","track_count":2,"new_release_date":"2026-10-16"}
@beatport-tracks-json
{"count":2,"results":[{"id":321,"name":"Runner","mix_name":"Extended Mix","number":1,"artists":[{"name":"Example DJ"}],"length_ms":402500,"release":{"id":987,"name":"Runner EP"}},{"id":322,"name":"Runner","mix_name":"Radio Edit","number":2,"artists":[{"name":"Example DJ"}],"length_ms":202500,"release":{"id":987,"name":"Runner EP"}}]}
'@
      try {
        Set-Clipboard -Value $beatport -ErrorAction Stop
        if(-not [FoobarHostWindow]::Click($window,$ClipboardButtonId)) {
          throw 'Beatport release import button not available in real Studio.'
        }
        $groups=[FoobarHostWindow]::ListCount($window,$ClipboardListId)
        $hint=[FoobarHostWindow]::Text($window,272)
        if($groups -lt 3 -or $hint -notmatch '^Release details and tentative CUE assignment') {
          throw "Beatport release UI was not populated ($groups groups; unexpected hint: $hint)."
        }
        if([FoobarHostWindow]::ListCount($window,294) -lt 1) {
          throw 'Beatport edition has no native field detail rows.'
        }
        Write-Host "HOST_BEATPORT_EXACT_EDITION_COMPARE_$Architecture=PASS (synthetic offline read-only evidence)"
      } finally {
        Set-Clipboard -Value '' -ErrorAction SilentlyContinue
      }
    }
    $forward=Start-Process -FilePath $exe -WorkingDirectory $target -ArgumentList $arg -PassThru
    if(-not $forward.WaitForExit(15000) -or $forward.ExitCode -ne 0) {
      throw 'Repeat context command failed.'
    }
    Start-Sleep -Seconds 1
    $found=[FoobarHostWindow]::Find([uint32]$proc.Id,$ExpectedWindowTitle)
    if($found.Length -ne 1 -or $found[0] -ne $window -or
       -not [FoobarHostWindow]::Responsive($window)) {
      throw 'Modeless Studio workspace was duplicated or blocked.'
    }
    Write-Host "HOST_WORKSPACE_REUSE_$Architecture=PASS"
    Assert-FoobarFixtureUnchanged -Path $fixture -Before $fixtureBefore
    Write-Host "HOST_WORKSPACE_SYNTHETIC_WAV_UNCHANGED_$Architecture=PASS"
    if($StalePhysicalProbe) {
      if(-not $OfflineClipboardTest -or $ClipboardButtonId -le 0 -or
         -not [FoobarHostWindow]::Enabled($window,$ClipboardButtonId)) {
        throw 'Cannot qualify stale source gate without a previously working native Import button.'
      }
      # Intentional mutation of ONLY disposable generated runner fixture.
      # Previously verified original WAV hash/timestamp stay recorded above.
      $file=[IO.File]::Open($fixture,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,
                            [IO.FileShare]::ReadWrite)
      try {
        $null=$file.Seek(-1,[IO.SeekOrigin]::End)
        $value=$file.ReadByte()
        $null=$file.Seek(-1,[IO.SeekOrigin]::End)
        $file.WriteByte([byte]($value -bxor 1))
      } finally { $file.Dispose() }
      [IO.File]::SetLastWriteTimeUtc($fixture,([DateTime]::UtcNow).AddMinutes(2))
      # A separate snapshot guard must reject disk-only changes even where
      # the foobar cached file_info has not been refreshed.
      Set-Clipboard -Value $OfflineClipboardTest -ErrorAction Stop
      try {
        if(-not [FoobarHostWindow]::Click($window,$ClipboardButtonId)) {
          throw 'Failed to deliver stale-source action to real Studio.'
        }
        Start-Sleep -Milliseconds 200
        $title=[FoobarHostWindow]::Text($window,0)
        if($title -ne 'Music Metadata Studio - STALE snapshot (Read-only)' -or
           [FoobarHostWindow]::Enabled($window,$ClipboardButtonId)) {
          throw "Disk mutation was not rejected by modeless Studio (title=$title)."
        }
        Write-Host "HOST_DISK_STALE_LOCKDOWN_$Architecture=PASS (deliberately changed disposable WAV)"
      } finally {
        Set-Clipboard -Value '' -ErrorAction SilentlyContinue
      }
    }
    Write-Host "MEDIA_WRITE_SAFETY_$Architecture=NOT_TESTED"
    Write-Host "FOOBAR_UI_$Architecture=PARTIAL (open, controls, reuse only)"
  } else {
    Write-Host "FOOBAR_UI_$Architecture=NOT_TESTED"
    Write-Host "MEDIA_WRITE_SAFETY_$Architecture=NOT_TESTED"
  }
} finally {
  if ($null -ne $proc) {
    try { if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } }
    catch { Write-Warning 'Could not stop disposable foobar process.' }
  }
  if (Test-Path -LiteralPath $dir) {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

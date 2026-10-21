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
  [bool]$ExternalCueProbe = $false,
  [bool]$EmbeddedCueProbe = $false,
  [bool]$MultiFileCueProbe = $false,
  [bool]$RawTargetProbe = $false,
  [bool]$StalePhysicalProbe = $false,
  [bool]$AuthorizedDiscogsProbe = $false,
  [string]$DiscogsReleaseId = '38012673',
  [ValidateRange(10,120)][int]$StartupTimeoutSeconds = 35
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'synthetic-wave.ps1')
. (Join-Path $PSScriptRoot 'pinned-installer-cache.ps1')

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
  public static bool Close(IntPtr hwnd) {
    IntPtr result;
    return SendMessageTimeoutW(hwnd,0x0010,IntPtr.Zero,IntPtr.Zero,2,5000,out result)!=IntPtr.Zero;
  }
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
  public static bool SwitchTab(IntPtr dialog,int tabId,int index) {
    var tab=GetDlgItem(dialog,tabId);
    if(tab==IntPtr.Zero) return false;
    // Never pass pointers to WM_NOTIFY across processes. Let the real tab
    // control itself generate TCN_SELCHANGE using ordinary keyboard events.
    IntPtr current;
    if(SendMessageTimeoutW(tab,0x130B,IntPtr.Zero,IntPtr.Zero,2,5000,out current)==IntPtr.Zero)
      return false;
    int from=checked((int)current.ToInt64());
    if(from<0 || index<0 || index>2) return false;
    for(int n=0;n<3 && from!=index;++n) {
      int key=from<index?0x27:0x25; // VK_RIGHT / VK_LEFT
      IntPtr unused;
      if(SendMessageTimeoutW(tab,0x0100,new IntPtr(key),IntPtr.Zero,2,5000,out unused)==IntPtr.Zero)
        return false;
      SendMessageTimeoutW(tab,0x0101,new IntPtr(key),IntPtr.Zero,2,5000,out unused);
      if(SendMessageTimeoutW(tab,0x130B,IntPtr.Zero,IntPtr.Zero,2,5000,out current)==IntPtr.Zero)
        return false;
      int now=checked((int)current.ToInt64());
      if(now==from) return false; // no invented tab selection
      from=now;
    }
    return from==index;
  }
  public static bool SelectListRow(IntPtr dialog,int listId,int index) {
    var list=GetDlgItem(dialog,listId);
    if(list==IntPtr.Zero || !IsWindowVisible(list) || index!=0) return false;
    // Pointer-bearing LVM_SETITEMSTATE cannot cross process boundaries.
    // A genuine mouse click runs inside the target native ListView process.
    IntPtr ignored;
    IntPtr clientPoint=new IntPtr((42<<16)|28); // below header, row 0
    if(SendMessageTimeoutW(list,0x0201,new IntPtr(1),clientPoint,2,5000,out ignored)==IntPtr.Zero)
      return false;
    SendMessageTimeoutW(list,0x0202,IntPtr.Zero,clientPoint,2,5000,out ignored);
    IntPtr selected;
    return SendMessageTimeoutW(list,0x1032,IntPtr.Zero,IntPtr.Zero,2,5000,out selected)!=IntPtr.Zero
       && selected.ToInt64()==1;
  }
  public static bool Command(IntPtr dialog,int id) {
    IntPtr result;
    return SendMessageTimeoutW(dialog,0x0111,new IntPtr(id),IntPtr.Zero,
                               2,8000,out result)!=IntPtr.Zero;
  }
  public static bool Enabled(IntPtr dialog,int id) {
    var control=GetDlgItem(dialog,id);
    return control!=IntPtr.Zero && IsWindowEnabled(control);
  }
  public static bool SetText(IntPtr dialog,int id,string value) {
    var control=GetDlgItem(dialog,id);
    if(control==IntPtr.Zero) return false;
    var ptr=Marshal.StringToHGlobalUni(value);
    try {
      IntPtr result;
      return SendMessageTimeoutW(control,0x000C,IntPtr.Zero,ptr,2,5000,out result)!=IntPtr.Zero
        && result!=IntPtr.Zero;
    } finally { Marshal.ZeroFreeGlobalAllocUnicode(ptr); }
  }
  public static bool SelectProvider(IntPtr dialog,int id,int index) {
    var combo=GetDlgItem(dialog,id);
    if(combo==IntPtr.Zero) return false;
    IntPtr result;
    if(SendMessageTimeoutW(combo,0x014E,new IntPtr(index),IntPtr.Zero,2,5000,out result)==IntPtr.Zero
      || result.ToInt64()!=index) return false;
    var command=new IntPtr((1<<16)|id);
    return SendMessageTimeoutW(dialog,0x0111,command,combo,2,5000,out result)!=IntPtr.Zero;
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
$discogsQaToken=$null
if($AuthorizedDiscogsProbe) {
  # Secrets are only allowed via environment-scoped, explicit manual QA.
  # Never inherit the secret into foobar.exe or put it on a command line.
  if($env:GITHUB_EVENT_NAME -ne 'workflow_dispatch' -or
      $env:GITHUB_REF -ne 'refs/heads/feature/online-metadata-discovery-foundation-20261009' -or
      -not $env:FB2K_DISCOGS_QA_TOKEN -or
      $env:FB2K_DISCOGS_QA_TOKEN -cnotmatch '^[A-Za-z0-9_-]{8,256}$' -or
      @('38012673','37332711','36397609','36819730') -cnotcontains $DiscogsReleaseId -or
      $StalePhysicalProbe) {
    throw 'AUTHORIZED_DISCOGS_PREFLIGHT=FAIL (manual authorized environment or allowlisted release required)'
  }
  $discogsQaToken=$env:FB2K_DISCOGS_QA_TOKEN
  [Environment]::SetEnvironmentVariable('FB2K_DISCOGS_QA_TOKEN',$null,'Process')
}

if (@(Get-Process -Name foobar2000 -ErrorAction SilentlyContinue).Count -gt 0) {
  throw 'Unrelated foobar2000 process exists: refuse non-isolated testing.'
}
$spec=$specs[$Architecture]
if (([uri]$spec.Url).Host -ne 'www.foobar2000.org') { throw 'Invalid official installer origin.' }
$dir=Join-Path $env:RUNNER_TEMP ('fb2k-host-'+$Architecture+'-'+[guid]::NewGuid().ToString('N'))
$target=Join-Path $dir 'host'
$installer=$null
$proc=$null
try {
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  # This richer runner retains all existing HWND/UIA, CUE, Beatport and
  # clipboard probes. Only its upstream-original EXE transport is changed.
  # The mirror is our license-compliant, byte-identical GitHub Release asset,
  # previously verified against independent Microsoft winget SHA256 pins.
  $filename = if ($Architecture -eq 'Win32') { 'foobar2000_v2.26.1.exe' } else { 'foobar2000-x64_v2.26.1.exe' }
  $mirrorUrl = 'https://github.com/lxsdd/dev-infrastructure-public/releases/download/foobar-ci-upstream-v2.26.1/' + $filename
  $installer=Get-FoobarPinnedInstaller -Architecture $Architecture -Version '2.26.1' `
    -Url $spec.Url -Sha256 $spec.Sha256 -CacheRoot $env:RUNNER_TEMP -MirrorUrl $mirrorUrl
  Write-Host "FOOBAR_INSTALLER_SOURCE=GITHUB_ORIGINAL_ASSET arch=$Architecture version=2.26.1"
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
    if($RawTargetProbe) {
      # Exercise the real native 3. Plan file locations tab, not merely the
      # pure planner or an open-window smoke. The only input is this runner's
      # disposable 8-kHz WAV; there is no actual move or write-capable path.
      if(-not [FoobarHostWindow]::SwitchTab($window,270,2) -or
         [FoobarHostWindow]::ListCount($window,261) -lt 1) {
        throw 'Real native File locations tab did not open or list a WAV.'
      }
      if(-not [FoobarHostWindow]::SetText($window,264,$dir) -or
         -not [FoobarHostWindow]::SetText($window,265,'%filename%') -or
         -not [FoobarHostWindow]::Click($window,267)) {
        throw 'Cannot generate read-only native raw location preview.'
      }
      if(-not [FoobarHostWindow]::SelectListRow($window,261,0) -or
         -not [FoobarHostWindow]::Command($window,41300)) {
        throw 'Actual native inspect raw destinations command failed.'
      }
      $hint=[FoobarHostWindow]::Text($window,272)
      if($hint -notmatch '^Raw target inspection: 1 candidate\(s\); present 0, missing 1, unqualified 0, physical source aliases 0\.' -or
         $hint -notmatch 'Final foobar destinations/CUE dependencies UNVERIFIED; no writes') {
        throw "Missing raw-target observation or final FileOps warning: $hint"
      }
      Write-Host "HOST_RAW_MISSING_TARGET_$Architecture=PASS (true absent raw candidate; no writes)"
      # A different Title Formatting projection now names the SAME existing
      # disposable WAV. Physical identity, not textual equality of paths,
      # must identify it as a self-targeting conflict.
      if(-not [FoobarHostWindow]::SetText($window,265,'%filename_ext%') -or
         -not [FoobarHostWindow]::Click($window,267) -or
         -not [FoobarHostWindow]::SelectListRow($window,261,0) -or
         -not [FoobarHostWindow]::Command($window,41300)) {
        throw 'Native existing source-as-target preflight could not run.'
      }
      $self=[FoobarHostWindow]::Text($window,272)
      if($self -notmatch '^Raw target inspection: 1 candidate\(s\); present 1, missing 0, unqualified 0, physical source aliases 1\.' -or
         $self -notmatch 'Final foobar destinations/CUE dependencies UNVERIFIED; no writes') {
        throw "Native source alias was not blocked as a physical conflict: $self"
      }
      Write-Host "HOST_RAW_SELF_TARGET_ALIAS_$Architecture=PASS (same physical WAV cannot be treated as new destination)"
      Assert-FoobarFixtureUnchanged -Path $fixture -Before $fixtureBefore
      Write-Host "HOST_RAW_DESTINATION_INSPECT_$Architecture=PASS (real File locations tab; missing + source-alias observations)"
      if(-not [FoobarHostWindow]::SwitchTab($window,270,0)) {
        throw 'Cannot restore online metadata tab after native File locations check.'
      }
    }
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
    if($AuthorizedDiscogsProbe) {
      # Deliberate, bounded official-token GET initiated via the real Studio
      # provider selector, masked token edit, exact release URL, and Search.
      # No scraping, mock network, or user audio. NEVER log response, header,
      # token, process environment, clipboard or native password control.
      try {
        if(-not [FoobarHostWindow]::SelectProvider($window,299,1)) {
          throw 'Discogs provider could not be selected in the native UI.'
        }
        if(-not [FoobarHostWindow]::SetText($window,301,$discogsQaToken)) {
          throw 'Masked Discogs token field was unavailable.'
        }
        $url='https://www.discogs.com/release/'+$DiscogsReleaseId
        if(-not [FoobarHostWindow]::SetText($window,291,$url)) {
          throw 'Exact release search field unavailable.'
        }
        if(-not [FoobarHostWindow]::Click($window,292)) {
          throw 'Authorized Discogs search button refused native activation.'
        }
        $confirmed=$false
        for($attempt=0;$attempt -lt 50;$attempt++) {
          Start-Sleep -Milliseconds 500
          $proc.Refresh()
          if($proc.HasExited) { throw 'foobar exited during authorized Discogs lookup.' }
          $hint=[FoobarHostWindow]::Text($window,272)
          if($hint -like 'Discogs read-only lookup failed:*') {
            throw 'AUTHORIZED_DISCOGS_LIVE=FAIL (official response rejected by component)'
          }
          if($hint -like 'Release details and tentative CUE assignment*') {
            $confirmed=$true
            break
          }
        }
        if(-not $confirmed) { throw 'AUTHORIZED_DISCOGS_LIVE=FAIL (no exact edition display)' }
        $groups=[FoobarHostWindow]::ListCount($window,271)
        $detail=[FoobarHostWindow]::ListCount($window,294)
        if($groups -lt 2 -or $detail -lt 1) {
          throw 'AUTHORIZED_DISCOGS_LIVE=FAIL (missing native release or field evidence)'
        }
        Assert-FoobarFixtureUnchanged -Path $fixture -Before $fixtureBefore
        Write-Host "HOST_AUTHORIZED_DISCOGS_EXACT_EDITION_$Architecture=PASS (official HTTPS, native read-only release and fields)"
        Write-Host "HOST_AUTHORIZED_DISCOGS_RELEASE_ID=$DiscogsReleaseId"
      } finally {
        # Best effort wipe from the actual masked native edit and shell.
        $null=[FoobarHostWindow]::SetText($window,301,'')
        $discogsQaToken=$null
        [Environment]::SetEnvironmentVariable('FB2K_DISCOGS_QA_TOKEN',$null,'Process')
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
    if($ExternalCueProbe) {
      if(-not $BeatportEditionProbe -or $ClipboardButtonId -le 0 -or
         $ClipboardListId -le 0 -or -not $ContextCommand) {
        throw 'External CUE host probe requires earlier read-only Beatport native test.'
      }
      # Two synthetic tracks share ONE disposable physical WAV. Foobar
      # enumerates the CUE virtual tracks; only exact original CUE bytes are
      # opened for inspection and the source itself is NEVER a write target.
      $cuePath=Join-Path $dir 'synthetic-edition.cue'
      $cueText=@'
TITLE "Runner EP"
PERFORMER "Example DJ"
REM GENRE "House"
REM GENRE "Progressive Trance"
REM CUSTOM "Never replace"
FILE "synthetic-8k-silence.wav" WAVE
  TRACK 01 AUDIO
    TITLE "Runner (Extended Mix)"
    PERFORMER "Example DJ"
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    TITLE "Runner (Radio Edit)"
    PERFORMER "Example DJ"
    INDEX 01 00:00:30
'@
      [IO.File]::WriteAllText($cuePath,$cueText,([Text.UTF8Encoding]::new($false)))
      $cueBefore=Get-FoobarFixtureSnapshot -Path $cuePath
      if(-not [FoobarHostWindow]::Close($window)) {
        throw 'Cannot close the existing modeless workspace before CUE test.'
      }
      for($i=0;$i -lt 20;$i++) {
        Start-Sleep -Milliseconds 200
        if([FoobarHostWindow]::Find([uint32]$proc.Id,$ExpectedWindowTitle).Length -eq 0) { break }
      }
      if([FoobarHostWindow]::Find([uint32]$proc.Id,$ExpectedWindowTitle).Length -ne 0) {
        throw 'Modeless workspace did not close before external CUE selection.'
      }
      $cueDispatch=Start-Process -FilePath $exe -WorkingDirectory $target -ArgumentList @('/add','/immediate',$cuePath) -PassThru
      if(-not $cueDispatch.WaitForExit(15000) -or $cueDispatch.ExitCode -ne 0) {
        throw 'Host cannot load synthetic external CUE.'
      }
      $leaf=($ContextCommand -split '/')[-1]
      $cueArg='/context_command:"'+$leaf+'" "'+$cuePath+'"'
      $cueForward=Start-Process -FilePath $exe -WorkingDirectory $target -ArgumentList $cueArg -PassThru
      if(-not $cueForward.WaitForExit(15000) -or $cueForward.ExitCode -ne 0) {
        throw 'External CUE context command refused by host.'
      }
      $cueWindow=[IntPtr]::Zero
      for($i=0;$i -lt 36;$i++) {
        Start-Sleep -Milliseconds 500
        $found=[FoobarHostWindow]::Find([uint32]$proc.Id,$ExpectedWindowTitle)
        if($found.Length -gt 1) { throw 'More than one native CUE workspace opened.' }
        if($found.Length -eq 1) { $cueWindow=$found[0]; break }
      }
      if($cueWindow -eq [IntPtr]::Zero) {
        throw 'External CUE context selection did not open the actual native Studio.'
      }
      if(-not [FoobarHostWindow]::Enabled($cueWindow,290)) {
        throw 'Selected external CUE does not enable native Inspect CUE.'
      }
      if(-not [FoobarHostWindow]::Click($cueWindow,290)) {
        throw 'Actual native Inspect CUE command was not activated.'
      }
      $cueRows=[FoobarHostWindow]::ListCount($cueWindow,$ClipboardListId)
      # Original fixture contains 10 CUE facts (global, tracks and FILE).
      # Studio's read-only physical FILE-reference observer must add 1.
      if($cueRows -lt 11) {
        throw "Native external CUE dependency row absent ($cueRows; expected >=11)."
      }
      Write-Host "HOST_EXTERNAL_CUE_SOURCE_REFERENCES_$Architecture=PASS (CUE originals + physical FILE preflight)"
      Write-Host "HOST_EXTERNAL_CUE_INSPECT_$Architecture=PASS (real native CUE source inventory)"
      # Identical synthetic two-mix edition (no actual Beatport service).
      # The original CUE has two REM GENRE instances, so the result MUST
      # keep all origins and forbid conflicting global replacement.
      $cueEdition=@'
@beatport-release-json
{"id":987,"name":"Runner EP","track_count":2,"new_release_date":"2026-10-16"}
@beatport-tracks-json
{"count":2,"results":[{"id":321,"name":"Runner","mix_name":"Extended Mix","number":1,"artists":[{"name":"Example DJ"}],"length_ms":402500,"release":{"id":987,"name":"Runner EP"}},{"id":322,"name":"Runner","mix_name":"Radio Edit","number":2,"artists":[{"name":"Example DJ"}],"length_ms":202500,"release":{"id":987,"name":"Runner EP"}}]}
'@
      try {
        Set-Clipboard -Value $cueEdition -ErrorAction Stop
        if(-not [FoobarHostWindow]::Enabled($cueWindow,$ClipboardButtonId) -or
           -not [FoobarHostWindow]::Click($cueWindow,$ClipboardButtonId)) {
          throw 'CUE edition import control refused actual native activation.'
        }
        $rows=[FoobarHostWindow]::ListCount($cueWindow,$ClipboardListId)
        $details=[FoobarHostWindow]::ListCount($cueWindow,294)
        $notice=[FoobarHostWindow]::Text($cueWindow,272)
        if($rows -lt 4 -or $details -lt 1 -or
           $notice -notmatch '^Release details and tentative CUE assignment') {
          throw "Native Beatport external CUE comparison missing ($rows summary, $details detail)."
        }
        Assert-FoobarFixtureUnchanged -Path $cuePath -Before $cueBefore
        Assert-FoobarFixtureUnchanged -Path $fixture -Before $fixtureBefore
        Write-Host "HOST_EXTERNAL_CUE_EDITION_COMPARE_$Architecture=PASS (2 mixes, read-only carrier)"
      } finally {
        Set-Clipboard -Value '' -ErrorAction SilentlyContinue
      }
      # Safety-negative after immutable fixture confirmation: change only
      # disposable synthetic .cue. Foobar may still have the OLD cached
      # metadata; Studio must compare captured disk file identity too.
      [IO.File]::AppendAllText($cuePath,
        ("REM QA_ONLY_MUTATION_AFTER_SNAPSHOT true"+[Environment]::NewLine),
        ([Text.UTF8Encoding]::new($false)))
      [IO.File]::SetLastWriteTimeUtc($cuePath,([DateTime]::UtcNow).AddMinutes(3))
      Set-Clipboard -Value $cueEdition -ErrorAction Stop
      try {
        if(-not [FoobarHostWindow]::Click($cueWindow,$ClipboardButtonId)) {
          throw 'Could not deliver stale CUE import action to native Studio.'
        }
        Start-Sleep -Milliseconds 220
        $staleTitle=[FoobarHostWindow]::Text($cueWindow,0)
        if($staleTitle -ne 'Music Metadata Studio - STALE snapshot (Read-only)' -or
           [FoobarHostWindow]::Enabled($cueWindow,$ClipboardButtonId)) {
          throw "External CUE disk-only mutation was not locked down (title=$staleTitle)."
        }
        Write-Host "HOST_EXTERNAL_CUE_STALE_LOCKDOWN_$Architecture=PASS (changed disposable CUE only)"
      } finally {
        Set-Clipboard -Value '' -ErrorAction SilentlyContinue
      }
      if(-not [FoobarHostWindow]::Close($cueWindow)) {
        throw 'Native external CUE workspace failed to close cleanly.'
      }
      # Return to the original WAV to qualify its independent stale gate.
      $arg='/context_command:"'+$leaf+'" "'+$fixture+'"'
      $restored=Start-Process -FilePath $exe -WorkingDirectory $target -ArgumentList $arg -PassThru
      if(-not $restored.WaitForExit(15000) -or $restored.ExitCode -ne 0) {
        throw 'Failed to restore original WAV for stale gate.'
      }
      $window=[IntPtr]::Zero
      for($i=0;$i -lt 32;$i++) {
        Start-Sleep -Milliseconds 300
        $found=[FoobarHostWindow]::Find([uint32]$proc.Id,$ExpectedWindowTitle)
        if($found.Length -eq 1) {$window=$found[0];break}
      }
      if($window -eq [IntPtr]::Zero) { throw 'Could not reopen WAV workspace.' }
      if(-not [FoobarHostWindow]::Enabled($window,$ClipboardButtonId)) {
        throw 'Original WAV workspace import control was not re-enabled.'
      }
    }
    if($MultiFileCueProbe) {
      if(-not $ExternalCueProbe -or -not $BeatportEditionProbe -or
         $ClipboardButtonId -le 0 -or $ClipboardListId -le 0) {
        throw 'Multi-FILE host test requires the qualified external CUE comparison path.'
      }
      # Two separate disposable audio sources (both valid synthetic silent
      # WAVs). Native foobar requires sequential TRACK 01/02 here. A
      # separate pure bridge test blocks repeated TRACK 01 across FILE
      # references as ambiguous, with no invented edition position.
      $second=Join-Path $dir 'synthetic-second.wav'
      if(Test-Path -LiteralPath $second) {
        throw 'Refusing to replace a previously existing WAV fixture.'
      }
      Copy-Item -LiteralPath $fixture -Destination $second -ErrorAction Stop
      $secondBefore=Get-FoobarFixtureSnapshot -Path $second
      $multiPath=Join-Path $dir 'synthetic-multifile.cue'
      if(Test-Path -LiteralPath $multiPath) {
        throw 'Refusing to replace a previously existing Multi-FILE CUE fixture.'
      }
      $multiCue=@'
TITLE "Runner Multi-FILE EP"
PERFORMER "Example DJ"
REM GENRE "House"
REM GENRE "Progressive Trance"
REM CUSTOM "Keep unknown metadata"
FILE "synthetic-8k-silence.wav" WAVE
  TRACK 01 AUDIO
    TITLE "Runner (Extended Mix)"
    INDEX 01 00:00:00
FILE "synthetic-second.wav" WAVE
  TRACK 02 AUDIO
    TITLE "Runner (Radio Edit)"
    INDEX 01 00:00:00
'@
      [IO.File]::WriteAllText($multiPath,$multiCue,([Text.UTF8Encoding]::new($false)))
      $multiBefore=Get-FoobarFixtureSnapshot -Path $multiPath
      if(-not [FoobarHostWindow]::Close($window)) {
        throw 'Could not close audio-only workspace before Multi-FILE test.'
      }
      for($i=0;$i -lt 20;$i++) {
        Start-Sleep -Milliseconds 200
        if([FoobarHostWindow]::Find([uint32]$proc.Id,$ExpectedWindowTitle).Length -eq 0) {break}
      }
      if([FoobarHostWindow]::Find([uint32]$proc.Id,$ExpectedWindowTitle).Length -ne 0) {
        throw 'Audio-only workspace did not close before Multi-FILE selection.'
      }
      $load=Start-Process -FilePath $exe -WorkingDirectory $target -ArgumentList @('/add','/immediate',$multiPath) -PassThru
      if(-not $load.WaitForExit(15000) -or $load.ExitCode -ne 0) {
        throw 'Real foobar failed to load synthetic two-source CUE.'
      }
      $leaf=($ContextCommand -split '/')[-1]
      $cueArg='/context_command:"'+$leaf+'" "'+$multiPath+'"'
      $cmd=Start-Process -FilePath $exe -WorkingDirectory $target -ArgumentList $cueArg -PassThru
      if(-not $cmd.WaitForExit(15000) -or $cmd.ExitCode -ne 0) {
        throw 'Multi-FILE native Prepare Tracks route was not accepted.'
      }
      $multiWindow=[IntPtr]::Zero
      for($i=0;$i -lt 36;$i++) {
        Start-Sleep -Milliseconds 400
        $found=[FoobarHostWindow]::Find([uint32]$proc.Id,$ExpectedWindowTitle)
        if($found.Length -gt 1) {throw 'Duplicate modeless Multi-FILE workspace.'}
        if($found.Length -eq 1) {$multiWindow=$found[0];break}
      }
      if($multiWindow -eq [IntPtr]::Zero) {
        throw 'Native Studio window did not open on two-file CUE.'
      }
      if(-not [FoobarHostWindow]::Enabled($multiWindow,290) -or
         -not [FoobarHostWindow]::Click($multiWindow,290)) {
        throw 'Native Multi-FILE CUE Inspect was unavailable.'
      }
      $originals=[FoobarHostWindow]::ListCount($multiWindow,$ClipboardListId)
      # Multi-FILE fixture contains 9 original CUE facts and 2 independent
      # physical FILE observations; an uninspected target cannot pass.
      if($originals -lt 11) {
        throw "Native Multi-FILE reference observer is incomplete ($originals; expected >=11)."
      }
      Write-Host "HOST_MULTIFILE_SOURCE_REFERENCES_$Architecture=PASS (2 FILE physical preflight rows)"
      Write-Host "HOST_MULTIFILE_CUE_INSPECT_$Architecture=PASS (2 independent FILEs, sequential native track numbering)"
      $edition=@'
@beatport-release-json
{"id":988,"name":"Runner Multi-FILE EP","track_count":2,"new_release_date":"2026-10-16"}
@beatport-tracks-json
{"count":2,"results":[{"id":331,"name":"Runner","mix_name":"Extended Mix","number":1,"artists":[{"name":"Example DJ"}],"length_ms":402500,"release":{"id":988,"name":"Runner Multi-FILE EP"}},{"id":332,"name":"Runner","mix_name":"Radio Edit","number":2,"artists":[{"name":"Example DJ"}],"length_ms":202500,"release":{"id":988,"name":"Runner Multi-FILE EP"}}]}
'@
      try {
        Set-Clipboard -Value $edition -ErrorAction Stop
        if(-not [FoobarHostWindow]::Enabled($multiWindow,$ClipboardButtonId) -or
           -not [FoobarHostWindow]::Click($multiWindow,$ClipboardButtonId)) {
          throw 'Native Multi-FILE edition import did not activate.'
        }
        $rows=[FoobarHostWindow]::ListCount($multiWindow,$ClipboardListId)
        $details=[FoobarHostWindow]::ListCount($multiWindow,294)
        $hint=[FoobarHostWindow]::Text($multiWindow,272)
        if($rows -lt 4 -or $details -lt 1 -or
           $hint -notmatch '^Release details and tentative CUE assignment') {
          throw "Multi-FILE edition compare UI missing ($rows summary/$details details)."
        }
        Assert-FoobarFixtureUnchanged -Path $multiPath -Before $multiBefore
        Assert-FoobarFixtureUnchanged -Path $second -Before $secondBefore
        Assert-FoobarFixtureUnchanged -Path $fixture -Before $fixtureBefore
        Write-Host "HOST_MULTIFILE_CUE_EDITION_COMPARE_$Architecture=PASS (read-only, 2 FILE refs)"
      } finally {Set-Clipboard -Value '' -ErrorAction SilentlyContinue}
      if(-not [FoobarHostWindow]::Close($multiWindow)) {
        throw 'Native Multi-FILE CUE workspace did not close cleanly.'
      }
      $returnArg='/context_command:"'+$leaf+'" "'+$fixture+'"'
      $restore=Start-Process -FilePath $exe -WorkingDirectory $target -ArgumentList $returnArg -PassThru
      if(-not $restore.WaitForExit(15000) -or $restore.ExitCode -ne 0) {
        throw 'Could not restore the single-WAV workspace after Multi-FILE test.'
      }
      $window=[IntPtr]::Zero
      for($i=0;$i -lt 32;$i++) {
        Start-Sleep -Milliseconds 300
        $found=[FoobarHostWindow]::Find([uint32]$proc.Id,$ExpectedWindowTitle)
        if($found.Length -eq 1) {$window=$found[0];break}
      }
      if($window -eq [IntPtr]::Zero -or
         -not [FoobarHostWindow]::Enabled($window,$ClipboardButtonId)) {
        throw 'Audio-only workspace was not restored after Multi-FILE test.'
      }
    }
    if($EmbeddedCueProbe) {
      if(-not $ExternalCueProbe -or -not $OfflineClipboardTest -or
         $ClipboardButtonId -le 0 -or $ClipboardListId -le 0) {
        throw 'Embedded CUE host probe requires qualified external CUE and offline comparison.'
      }
      # Locally synthesized valid FLAC with 1-second silent constant frame
      # and an embedded multiline CUESHEET Vorbis comment (two tracks).
      # Python stdlib is available on windows-2022; no media encoder,
      # online download, or tag/FLAC writer is used.
      $flac=Join-Path $dir 'synthetic-embedded.flac'
      & python (Join-Path $PSScriptRoot 'synthetic-embedded-flac.py') $flac
      if($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $flac)) {
        throw 'Deterministic embedded CUE FLAC fixture was not generated.'
      }
      $flacBefore=Get-FoobarFixtureSnapshot -Path $flac
      if(-not [FoobarHostWindow]::Close($window)) {
        throw 'Could not close existing WAV workspace for embedded FLAC.'
      }
      for($i=0;$i -lt 20;$i++) {
        Start-Sleep -Milliseconds 200
        if([FoobarHostWindow]::Find([uint32]$proc.Id,$ExpectedWindowTitle).Length -eq 0) {break}
      }
      if([FoobarHostWindow]::Find([uint32]$proc.Id,$ExpectedWindowTitle).Length -ne 0) {
        throw 'Previous workspace not closed before FLAC context selection.'
      }
      $flacDispatch=Start-Process -FilePath $exe -WorkingDirectory $target -ArgumentList @('/add','/immediate',$flac) -PassThru
      if(-not $flacDispatch.WaitForExit(15000) -or $flacDispatch.ExitCode -ne 0) {
        throw 'Native foobar did not import the deterministic FLAC.'
      }
      $leaf=($ContextCommand -split '/')[-1]
      $flacArg='/context_command:"'+$leaf+'" "'+$flac+'"'
      $launch=Start-Process -FilePath $exe -WorkingDirectory $target -ArgumentList $flacArg -PassThru
      if(-not $launch.WaitForExit(15000) -or $launch.ExitCode -ne 0) {
        throw 'Native embedded FLAC context command failed.'
      }
      $flacWindow=[IntPtr]::Zero
      for($i=0;$i -lt 35;$i++) {
        Start-Sleep -Milliseconds 400
        $found=[FoobarHostWindow]::Find([uint32]$proc.Id,$ExpectedWindowTitle)
        if($found.Length -gt 1) {throw 'Duplicate native FLAC workspace.'}
        if($found.Length -eq 1) {$flacWindow=$found[0];break}
      }
      if($flacWindow -eq [IntPtr]::Zero) {throw 'Embedded FLAC did not open native Studio.'}
      if(-not [FoobarHostWindow]::Enabled($flacWindow,290)) {
        throw 'Physical FLAC does not expose embedded CUE Inspect action.'
      }
      if(-not [FoobarHostWindow]::Click($flacWindow,290)) {
        throw 'Native Inspect CUE refused embedded physical FLAC.'
      }
      $flacFields=[FoobarHostWindow]::ListCount($flacWindow,$ClipboardListId)
      if($flacFields -lt 8) {
        throw "Native embedded CUE inventory is missing ($flacFields rows)."
      }
      Write-Host "HOST_EMBEDDED_FLAC_CUE_INSPECT_$Architecture=PASS (physical Vorbis-comment CUESHEET)"
      # Run a full fabricated edition through this exact native CUE
      # comparison path; its identity is unverified, never an auto write.
      $flacEdition=@'
@beatport-release-json
{"id":987,"name":"Runner Embedded EP","track_count":2,"new_release_date":"2026-10-16"}
@beatport-tracks-json
{"count":2,"results":[{"id":321,"name":"Runner","mix_name":"Extended Mix","number":1,"artists":[{"name":"Example DJ"}],"length_ms":402500,"release":{"id":987,"name":"Runner Embedded EP"}},{"id":322,"name":"Runner","mix_name":"Radio Edit","number":2,"artists":[{"name":"Example DJ"}],"length_ms":202500,"release":{"id":987,"name":"Runner Embedded EP"}}]}
'@
      try {
        Set-Clipboard -Value $flacEdition -ErrorAction Stop
        if(-not [FoobarHostWindow]::Enabled($flacWindow,$ClipboardButtonId) -or
           -not [FoobarHostWindow]::Click($flacWindow,$ClipboardButtonId)) {
          throw 'Native read-only embedded FLAC edition import refused.'
        }
        $summary=[FoobarHostWindow]::ListCount($flacWindow,$ClipboardListId)
        $detail=[FoobarHostWindow]::ListCount($flacWindow,294)
        $hint=[FoobarHostWindow]::Text($flacWindow,272)
        if($summary -lt 4 -or $detail -lt 1 -or
           $hint -notmatch '^Release details and tentative CUE assignment') {
          throw "Embedded FLAC CUE edition native comparison failed ($summary/$detail; $hint)."
        }
        Assert-FoobarFixtureUnchanged -Path $flac -Before $flacBefore
        Assert-FoobarFixtureUnchanged -Path $fixture -Before $fixtureBefore
        Write-Host "HOST_EMBEDDED_FLAC_CUE_EDITION_COMPARE_$Architecture=PASS (read-only synthetic edition)"
      } finally {
        Set-Clipboard -Value '' -ErrorAction SilentlyContinue
      }
      # After the byte/timestamp PASS: mutate only the disposable FLAC.
      # This must invalidate the physical backing source even if foobar
      # exposes a virtual subsong whose cached metadata is unchanged.
      $file=[IO.File]::Open($flac,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,
                            [IO.FileShare]::ReadWrite)
      try {
        $null=$file.Seek(-1,[IO.SeekOrigin]::End)
        $value=$file.ReadByte()
        $null=$file.Seek(-1,[IO.SeekOrigin]::End)
        $file.WriteByte([byte]($value -bxor 1))
      } finally {$file.Dispose()}
      [IO.File]::SetLastWriteTimeUtc($flac,([DateTime]::UtcNow).AddMinutes(4))
      try {
        Set-Clipboard -Value $flacEdition -ErrorAction Stop
        if(-not [FoobarHostWindow]::Click($flacWindow,$ClipboardButtonId)) {
          throw 'Could not activate actual native embedded-CUE stale-check action.'
        }
        Start-Sleep -Milliseconds 240
        $title=[FoobarHostWindow]::Text($flacWindow,0)
        if($title -ne 'Music Metadata Studio - STALE snapshot (Read-only)' -or
           [FoobarHostWindow]::Enabled($flacWindow,$ClipboardButtonId)) {
          throw "Embedded FLAC source mutation did not lock the workspace ($title)."
        }
        Write-Host "HOST_EMBEDDED_FLAC_STALE_LOCKDOWN_$Architecture=PASS (disposable FLAC only)"
      } finally {Set-Clipboard -Value '' -ErrorAction SilentlyContinue}
      if(-not [FoobarHostWindow]::Close($flacWindow)) {
        throw 'Native embedded FLAC workspace did not close.'
      }
      $arg='/context_command:"'+$leaf+'" "'+$fixture+'"'
      $restore=Start-Process -FilePath $exe -WorkingDirectory $target -ArgumentList $arg -PassThru
      if(-not $restore.WaitForExit(15000) -or $restore.ExitCode -ne 0) {
        throw 'Could not restore original WAV for final stale source test.'
      }
      $window=[IntPtr]::Zero
      for($i=0;$i -lt 32;$i++) {
        Start-Sleep -Milliseconds 300
        $found=[FoobarHostWindow]::Find([uint32]$proc.Id,$ExpectedWindowTitle)
        if($found.Length -eq 1) {$window=$found[0];break}
      }
      if($window -eq [IntPtr]::Zero) {
        throw 'Original WAV workspace was not restored after embedded FLAC.'
      }
    }
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

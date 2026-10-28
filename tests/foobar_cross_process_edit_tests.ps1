#requires -Version 7.2
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Test the EXACT C# host helper embedded in the shared action, not a copy.
# All windows and data are disposable synthetic fixtures in separate pwsh
# processes. No foobar, token, user music or productive metadata is involved.
$hostScript = Join-Path $PSScriptRoot '../.github/actions/foobar-host-smoke/host-smoke.ps1'
$source = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $hostScript).Path)
$match = [regex]::Match($source, "(?s)Add-Type -TypeDefinition @'\r?\n(?<code>.*?)\r?\n'@")
if (-not $match.Success) { throw 'Cannot locate the actual FoobarHostWindow class.' }
Add-Type -TypeDefinition $match.Groups['code'].Value -ErrorAction Stop

$child = Join-Path $env:RUNNER_TEMP ('synthetic-remote-edit-' + [guid]::NewGuid().ToString('N') + '.ps1')
$childSource = @'
# Disposable separate process; only Win32 predefined STATIC/EDIT classes.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class SyntheticRemoteEdit {
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern IntPtr CreateWindowExW(uint ex,string cls,string text,uint style,
      int x,int y,int width,int height,IntPtr parent,IntPtr id,IntPtr instance,IntPtr param);
}
"@
$window = [SyntheticRemoteEdit]::CreateWindowExW(
  0,'STATIC','SYNTHETIC_REMOTE_EDIT_20261028',0x10CF0000,
  20,20,320,120,[IntPtr]::Zero,[IntPtr]::Zero,[IntPtr]::Zero,[IntPtr]::Zero)
if($window -eq [IntPtr]::Zero) { throw 'Synthetic top-level window creation failed.' }
$edit = [SyntheticRemoteEdit]::CreateWindowExW(
  0,'EDIT','1000 Years',0x50000080,
  10,10,200,24,$window,[IntPtr]291,[IntPtr]::Zero,[IntPtr]::Zero)
if($edit -eq [IntPtr]::Zero) { throw 'Synthetic EDIT creation failed.' }
for($tick=0;$tick -lt 500;$tick++) {
  [System.Windows.Forms.Application]::DoEvents()
  Start-Sleep -Milliseconds 25
}
'@
$proc=$null
try {
  [IO.File]::WriteAllText($child,$childSource,[Text.UTF8Encoding]::new($false))
  $pwsh=(Get-Command pwsh -ErrorAction Stop).Source
  $proc=Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile','-NonInteractive','-Sta','-File',('"' + $child + '"')) -PassThru
  $window=[IntPtr]::Zero
  for($i=0;$i -lt 50;$i++) {
    Start-Sleep -Milliseconds 100
    $proc.Refresh()
    if($proc.HasExited) { throw 'Synthetic child exited before verification.' }
    $found=[FoobarHostWindow]::Find([uint32]$proc.Id,'SYNTHETIC_REMOTE_EDIT_20261028')
    if($found.Length -ne 0) { $window=$found[0];break }
  }
  if($window -eq [IntPtr]::Zero) { throw 'Synthetic other-process top-level HWND not found.' }
  $remote=[FoobarHostWindow]::GetDlgItem($window,291)
  if($remote -eq [IntPtr]::Zero) { throw 'Synthetic remote EDIT control ID missing.' }
  $title=[FoobarHostWindow]::Text($window,291)
  if($title -cne '1000 Years') {
    throw "Cross-process EDIT WM_GETTEXT produced unexpected length $($title.Length)."
  }
  if([FoobarHostWindow]::Text($window,0) -cne 'SYNTHETIC_REMOTE_EDIT_20261028') {
    throw 'Top-level caption behavior regressed.'
  }
  if([FoobarHostWindow]::Text($window,292) -cne '') {
    throw 'Missing native control did not fail closed.'
  }
  Write-Host 'CROSS_PROCESS_EDIT_WM_GETTEXT=PASS (real foreign HWND, original helper, no product writes)'
} finally {
  if($null -ne $proc) {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    $proc.Dispose()
  }
  Remove-Item -LiteralPath $child -Force -ErrorAction SilentlyContinue
}

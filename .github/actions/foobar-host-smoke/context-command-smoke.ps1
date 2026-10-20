#requires -Version 7.2
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Exe,
  [Parameter(Mandatory)][string]$WorkingDirectory,
  [Parameter(Mandatory)][int]$HostProcessId,
  [Parameter(Mandatory)][string]$Command,
  [Parameter(Mandatory)][string]$ExpectedWindowTitle,
  [Parameter(Mandatory)][string[]]$FixturePaths,
  [ValidateRange(10,180)][int]$TimeoutSeconds = 90
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:GITHUB_ACTIONS -ne 'true' -or [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
  throw 'Context smoke is restricted to disposable GitHub Actions jobs.'
}
if (-not $Command.Contains('no tag writes')) {
  throw 'Refusing context smoke without an explicitly named no-tag-writes action.'
}
if ($ExpectedWindowTitle -notmatch 'NO WRITE') {
  throw 'Expected window must independently identify NO WRITE mode.'
}
if ($FixturePaths.Count -lt 1 -or $FixturePaths.Count -gt 4) {
  throw 'Use one to four runner-generated disposable fixtures.'
}
foreach ($file in $FixturePaths) {
  $resolved = (Resolve-Path -LiteralPath $file -ErrorAction Stop).Path
  if (-not $resolved.StartsWith($env:RUNNER_TEMP, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Non-disposable fixture path refused.'
  }
}

# Only check a verified title belonging to the host's actual process,
# never an arbitrary visible window belonging to another program.
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class FoobarContextWindowProbe {
  private delegate bool EnumWindowsCallback(IntPtr hwnd, IntPtr param);
  [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr param);
  [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hwnd, StringBuilder buffer, int maxCount);
  public static bool HostHasTitle(int hostPid, string title) {
    bool found = false;
    EnumWindows((hwnd, param) => {
      uint pid;
      GetWindowThreadProcessId(hwnd, out pid);
      if (pid == (uint)hostPid) {
        var text = new StringBuilder(512);
        GetWindowText(hwnd, text, text.Capacity);
        if (text.ToString().IndexOf(title, StringComparison.OrdinalIgnoreCase) >= 0) found = true;
      }
      return !found;
    }, IntPtr.Zero);
    return found;
  }
}
'@ -ErrorAction Stop

$snapshots = @($FixturePaths | ForEach-Object { Get-FoobarFixtureSnapshot -Path $_ })
# Explicitly supply files to foobar's built-in /context_command dispatcher.
# The hosted process remains the only allowed target; no playback is started.
$argsList = @('/context_command:' + $Command)
foreach ($file in $FixturePaths) { $argsList += ('"' + $file + '"') }
$dispatch = $null
try {
  $dispatch = Start-Process -FilePath $Exe -WorkingDirectory $WorkingDirectory -ArgumentList $argsList -PassThru
  if (-not $dispatch.WaitForExit(20000)) { throw 'Context command launcher timed out.' }
  if ($dispatch.ExitCode -ne 0) { throw "Context command launcher failed: $($dispatch.ExitCode)" }
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  $visible = $false
  while ([DateTime]::UtcNow -lt $deadline) {
    $hostProcess = Get-Process -Id $HostProcessId -ErrorAction Stop
    if ($hostProcess.HasExited) { throw 'foobar host exited during diagnostic context command.' }
    if ([FoobarContextWindowProbe]::HostHasTitle($HostProcessId, $ExpectedWindowTitle)) {
      $visible = $true
      break
    }
    Start-Sleep -Milliseconds 500
  }
  if (-not $visible) { throw 'CONTEXT_COMMAND_RESULT_WINDOW=FAIL: expected diagnostic result title absent.' }
  for ($i=0; $i -lt $FixturePaths.Count; ++$i) {
    Assert-FoobarFixtureUnchanged -Path $FixturePaths[$i] -Before $snapshots[$i]
  }
  Write-Host 'CONTEXT_COMMAND_RESULT_WINDOW=PASS'
  Write-Host 'CONTEXT_COMMAND_FIXTURE_NO_WRITE=PASS'
} finally {
  if ($null -ne $dispatch) {
    try { if (-not $dispatch.HasExited) { Stop-Process -Id $dispatch.Id -Force -ErrorAction Stop } }
    catch { Write-Warning 'Could not stop disposable context command launcher.' }
  }
}

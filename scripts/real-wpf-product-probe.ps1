#requires -Version 5.1
# Actual pinned production WPF window. No user data or screenshot outputs.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProductExe,
    [ValidateRange(5,60)][int]$TimeoutSeconds = 25,
    [switch]$RequireWindowFits
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows-ui-accessibility.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ProductionWindowProbe {
    [DllImport("user32.dll", SetLastError=true)] public static extern bool SetForegroundWindow(IntPtr hwnd);
}
'@
if ($env:GITHUB_ACTIONS -ne 'true' -or -not $env:RUNNER_TEMP) {
    throw 'The production WPF GUI probe is only permitted in a disposable GitHub Actions runner.'
}
$exe = [IO.Path]::GetFullPath($ProductExe)
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'Pinned WPF product executable not found.' }
if ((Get-Item -LiteralPath $exe).Length -lt 65536) { throw 'Unexpected WPF application binary size.' }
$work = Join-Path $env:RUNNER_TEMP ('wpf-visual-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$proc = $null
try {
    # Separate process-only environment; no developer or end-user profile.
    $env:LOCALAPPDATA = Join-Path $work 'Local'
    $env:APPDATA = Join-Path $work 'Roaming'
    $env:TEMP = Join-Path $work 'Temp'
    foreach ($folder in @($env:LOCALAPPDATA,$env:APPDATA,$env:TEMP)) {
        [void][IO.Directory]::CreateDirectory($folder)
    }
    $proc = Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe) -PassThru
    $handle = [IntPtr]::Zero
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 400
        $proc.Refresh()
        if ($proc.HasExited) { throw 'Real WPF product terminated before the main window appeared.' }
        $handle = $proc.MainWindowHandle
        if ($handle -ne [IntPtr]::Zero) { break }
    }
    if ($handle -eq [IntPtr]::Zero) { throw 'Visible WPF product main window not created.' }
    [void][ProductionWindowProbe]::SetForegroundWindow($handle)
    Start-Sleep -Milliseconds 700
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
    if ($null -eq $root -or $root.Current.Name -ne 'rekordbox MyTagSync') {
        throw 'Wrong or missing real product window title.'
    }
    Write-Host 'PRODUCTION_WPF_MAIN_WINDOW=PASS'
    # The production WPF window must render non-blank pixels, not merely
    # register a UIA tree. Sample a private in-memory GDI bitmap only.
    # Never save pixels, hash them into logs, or upload any image.
    $bitmap = $null
    $graphics = $null
    try {
        $clientRect = $root.Current.BoundingRectangle
        $workRect = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $left = [int][math]::Max($workRect.Left, $clientRect.Left + 16)
        $top = [int][math]::Max($workRect.Top, $clientRect.Top + 16)
        $right = [int][math]::Min($workRect.Right, $clientRect.Right - 16)
        $bottom = [int][math]::Min($workRect.Bottom, $clientRect.Bottom - 16)
        $width = [int][math]::Min(500, $right - $left)
        $height = [int][math]::Min(280, $bottom - $top)
        if ($width -lt 200 -or $height -lt 120) {
            throw 'The visible production window provides insufficient sample area.'
        }
        $bitmap = New-Object System.Drawing.Bitmap($width, $height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen(
            (New-Object System.Drawing.Point($left, $top)),
            [System.Drawing.Point]::Empty, $bitmap.Size)
        $colors = New-Object 'System.Collections.Generic.HashSet[int]'
        for ($row = 0; $row -lt $height; $row += 4) {
            for ($column = 0; $column -lt $width; $column += 4) {
                [void]$colors.Add($bitmap.GetPixel($column, $row).ToArgb())
            }
        }
        if ($colors.Count -lt 6) {
            throw 'Real WPF client area appears uniformly blank on the graphical desktop.'
        }
        Write-Host 'PRODUCTION_WPF_RENDERED_PIXELS=PASS_IN_MEMORY_ONLY'
    } finally {
        if ($null -ne $graphics) { $graphics.Dispose() }
        if ($null -ne $bitmap) { $bitmap.Dispose() }
    }

    foreach ($check in @(
        @{ Tag='SOURCE_NAME'; Value='foobar2000 Bridge snapshot directory'; Property=[System.Windows.Automation.AutomationElement]::NameProperty },
        @{ Tag='FIND_SOURCES_NAME'; Value='Find sources'; Property=[System.Windows.Automation.AutomationElement]::NameProperty },
        @{ Tag='SOURCE_ID'; Value='BridgeDirectoryTextBox'; Property=[System.Windows.Automation.AutomationElement]::AutomationIdProperty },
        @{ Tag='FIND_SOURCES_ID'; Value='DiscoverSourceButton'; Property=[System.Windows.Automation.AutomationElement]::AutomationIdProperty }
    )) {
        $query = [System.Windows.Automation.PropertyCondition]::new($check.Property, $check.Value)
        $count = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $query).Count
        Write-Host ('PRODUCTION_WPF_UIA_' + $check.Tag + '_COUNT=' + $count)
    }
    $result = Test-WindowsUiAccessibility -WindowHandle $handle -RequiredNames @('foobar2000 Bridge snapshot directory', 'Find sources') -RequiredAutomationIds @('BridgeDirectoryTextBox', 'DiscoverSourceButton')
    if (-not $result.Passed) {
        throw ('Actual WPF accessibility/visible-control geometry failed: ' + ($result.Issues -join ','))
    }
    Write-Host 'PRODUCTION_WPF_UIA_VISIBLE_SOURCE_CONTROLS=PASS'
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'BridgeDirectoryTextBox')
    $field = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if ($null -eq $field -or -not $field.Current.IsKeyboardFocusable) {
        throw 'Actual WPF source field is not keyboard-focusable.'
    }
    $field.SetFocus()
    Start-Sleep -Milliseconds 100
    if (-not $field.Current.HasKeyboardFocus) { throw 'Actual WPF source field rejected keyboard focus.' }
    Write-Host 'PRODUCTION_WPF_KEYBOARD_FOCUS=PASS'
    $workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $rect = $root.Current.BoundingRectangle
    $windowFits = $rect.Left -ge $workArea.Left -and $rect.Top -ge $workArea.Top -and
        $rect.Right -le $workArea.Right -and $rect.Bottom -le $workArea.Bottom
    Write-Host ('PRODUCTION_WPF_SCREEN_WORKAREA=' + $workArea.Width + 'x' + $workArea.Height)
    if ($windowFits) {
        Write-Host 'PRODUCTION_WPF_WINDOW_FITS_WORKAREA=PASS'
    } else {
        # Product min window 1050x700 exceeds the stock 1024x768 GUI.
        Write-Host 'PRODUCTION_WPF_WINDOW_FITS_WORKAREA=LIMITED_BY_DISPLAY_RESOLUTION'
    }
    if ($RequireWindowFits -and -not $windowFits) {
        throw 'FAIL: production WPF window does not fit the actual primary Windows work area.'
    }
    Write-Host 'PRODUCTION_WPF_PROBE=PASS_READ_ONLY'
} finally {
    if ($null -ne $proc) {
        try {
            if (-not $proc.HasExited) {
                [void]$proc.CloseMainWindow()
                if (-not $proc.WaitForExit(2000)) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
            }
        } catch {
            try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
        } finally { $proc.Dispose() }
    }
    if (Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Force -Recurse -ErrorAction SilentlyContinue
    }
}

#requires -Version 5.1
# Disposable synthetic window probe; outputs capability flags, not screenshots.
# No production apps, user profile files, tokens, music, or uploaded binaries.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot 'windows-ui-geometry.ps1')
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DesktopSessionProbe {
    [DllImport("user32.dll", SetLastError=true)]
    public static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool CloseDesktop(IntPtr handle);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")]
    public static extern void mouse_event(uint flags, uint x, uint y, uint data, IntPtr extra);
}
'@
$form = $null
$bitmap = $null
$graphics = $null
$inputDesktop = [IntPtr]::Zero
try {
    $sessionId = (Get-Process -Id $PID).SessionId
    $interactive = [Environment]::UserInteractive
    $inputDesktop = [DesktopSessionProbe]::OpenInputDesktop(0, $false, 1)
    $hasInputDesktop = $inputDesktop -ne [IntPtr]::Zero
    Write-Host "RUNNER_SESSION_ID=$sessionId"
    Write-Host "USER_INTERACTIVE=$interactive"
    Write-Host "INPUT_DESKTOP_AVAILABLE=$hasInputDesktop"
    Write-Host "SCREEN_BOUNDS=$([System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width)x$([System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height)"

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'SYNTHETIC_GRAPHICS_TEST_ONLY'
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.Location = New-Object System.Drawing.Point(120, 100)
    $form.Size = New-Object System.Drawing.Size(310, 220)
    $form.BackColor = [System.Drawing.Color]::FromArgb(18, 178, 74)
    $form.ShowInTaskbar = $false

    $button = New-Object System.Windows.Forms.Button
    $button.Text = 'Read-only test'
    $button.Name = 'SyntheticProbeButton'
    $button.AccessibleName = 'SyntheticProbeButton'
    $button.Location = New-Object System.Drawing.Point(12, 12)
    $button.Size = New-Object System.Drawing.Size(160, 35)
    $form.Controls.Add($button)
    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Name = 'SyntheticKeyboardInput'
    $textBox.AccessibleName = 'SyntheticKeyboardInput'
    $textBox.Text = 'seed'
    $textBox.TabIndex = 0
    $textBox.Location = New-Object System.Drawing.Point(12, 64)
    $textBox.Size = New-Object System.Drawing.Size(160, 27)
    $form.Controls.Add($textBox)
    $script:syntheticButtonClicked = $false
    $button.Add_Click({ $script:syntheticButtonClicked = $true })
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 350

    $uia = 'NOT_AVAILABLE'
    try {
        Add-Type -AssemblyName UIAutomationClient
        $element = [System.Windows.Automation.AutomationElement]::FromHandle($button.Handle)
        if ($null -eq $element) {
            $uia = 'NO_ELEMENT'
        } else {
            $name = $element.Current.Name
            $kind = $element.Current.ControlType.ProgrammaticName
            Write-Host "SYNTHETIC_UIA_CONTROL_TYPE=$kind"
            Write-Host "SYNTHETIC_UIA_CONTROL_NAME=$name"
            if (($kind -eq 'ControlType.Button' -or $kind -eq 'ControlType.Pane') -and
                ($name -eq 'SyntheticProbeButton' -or $name -eq 'Read-only test')) {
                $uia = 'PASS'
            } else {
                $uia = 'NO_MATCH'
            }
        }
    } catch {
        $uia = 'UNAVAILABLE_' + $_.Exception.GetType().Name
    }
    Write-Host "SYNTHETIC_UIA_ELEMENT=$uia"

    $pixel = 'UNAVAILABLE'
    try {
        $point = $form.PointToScreen((New-Object System.Drawing.Point(60,90)))
        $bitmap = New-Object System.Drawing.Bitmap(2,2)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($point, [System.Drawing.Point]::Empty, $bitmap.Size)
        $color = $bitmap.GetPixel(0,0)
        $pixel = if ($color.R -eq 18 -and $color.G -eq 178 -and $color.B -eq 74) {'PASS'} else {'PIXEL_MISMATCH'}
    } catch {
        $pixel = 'UNAVAILABLE_' + $_.Exception.GetType().Name
    }
    Write-Host "SYNTHETIC_DESKTOP_PIXEL_CAPTURE=$pixel"
    # Measure a real onscreen control against its parent and button text.
    $good = Get-SafeDesktopLayoutDiagnostics -Window $form -Controls @($button, $textBox)
    $layout = if ($good.Passed) { 'PASS' } else { 'FAIL_' + ($good.Issues -join '_') }
    Write-Host "SYNTHETIC_CONTROL_LAYOUT=$layout"

    # Deliberately clipped fixture must be detected. Never accept a checker
    # that reports a PASS for all input regardless of actual geometry.
    $bad = New-Object System.Windows.Forms.Button
    $bad.Name = 'DeliberatelyClippedFixture'
    $bad.Text = 'Deliberately oversized label must be flagged'
    $bad.Location = New-Object System.Drawing.Point(190, 105)
    $bad.Size = New-Object System.Drawing.Size(75, 30)
    $form.Controls.Add($bad)
    try {
        [System.Windows.Forms.Application]::DoEvents()
        $badResult = Get-SafeDesktopLayoutDiagnostics -Window $form -Controls @($bad)
        $negative = if ((-not $badResult.Passed) -and
            ($badResult.Issues -contains 'BUTTON_TEXT_CLIPPED')) { 'PASS' } else { 'MISSED_CLIPPED_TEXT' }
        Write-Host "SYNTHETIC_NEGATIVE_TEXT_CLIPPING=$negative"
    } finally {
        $form.Controls.Remove($bad)
        $bad.Dispose()
    }

    $keyboard = 'NOT_TESTED'
    try {
        [void][DesktopSessionProbe]::SetForegroundWindow($form.Handle)
        $form.Activate()
        [void]$textBox.Focus()
        [System.Windows.Forms.Application]::DoEvents()
        [System.Windows.Forms.SendKeys]::SendWait('{END}Z')
        [System.Windows.Forms.Application]::DoEvents()
        $keyboard = if ($textBox.Text -eq 'seedZ') { 'PASS' } else { 'NO_EDIT_EVENT' }
    } catch {
        $keyboard = 'UNAVAILABLE_' + $_.Exception.GetType().Name
    }
    Write-Host "SYNTHETIC_KEYBOARD_INPUT=$keyboard"
    $mouse = 'NOT_TESTED'
    try {
        [void][DesktopSessionProbe]::SetForegroundWindow($form.Handle)
        $form.Activate()
        [System.Windows.Forms.Application]::DoEvents()
        $targetPoint = $button.PointToScreen((New-Object System.Drawing.Point(60, 17)))
        if (-not [DesktopSessionProbe]::SetCursorPos($targetPoint.X, $targetPoint.Y)) {
            throw 'Could not position synthetic mouse cursor.'
        }
        [DesktopSessionProbe]::mouse_event(2, 0, 0, 0, [IntPtr]::Zero)
        [DesktopSessionProbe]::mouse_event(4, 0, 0, 0, [IntPtr]::Zero)
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 80
        [System.Windows.Forms.Application]::DoEvents()
        $mouse = if ($script:syntheticButtonClicked) { 'PASS' } else { 'NO_CLICK_EVENT' }
    } catch {
        $mouse = 'UNAVAILABLE_' + $_.Exception.GetType().Name
    }
    Write-Host "SYNTHETIC_MOUSE_INPUT=$mouse"
    if ($uia -eq 'PASS' -and $pixel -eq 'PASS' -and $mouse -eq 'PASS' -and
        $keyboard -eq 'PASS' -and $layout -eq 'PASS' -and $negative -eq 'PASS' -and
        $hasInputDesktop -and $interactive) {
        Write-Host 'GRAPHICS_SESSION_CLASS=INTERACTIVE_UIA_MOUSE_KEYBOARD_AND_GEOMETRY_PASS'
    } else {
        Write-Host 'GRAPHICS_SESSION_CLASS=PARTIAL_DESKTOP_CAPABILITY'
    }
    Write-Host 'SAFE_PROBE=PASS (no production app, no external upload, no screenshot saved)'
} finally {
    if ($null -ne $graphics) { $graphics.Dispose() }
    if ($null -ne $bitmap) { $bitmap.Dispose() }
    if ($null -ne $form) { $form.Close(); $form.Dispose() }
    if ($inputDesktop -ne [IntPtr]::Zero) { [void][DesktopSessionProbe]::CloseDesktop($inputDesktop) }
}

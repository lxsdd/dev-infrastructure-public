#requires -Version 5.1
# Disposable synthetic window probe; outputs capability flags, not screenshots.
# No production apps, user profile files, tokens, music, or uploaded binaries.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DesktopSessionProbe {
    [DllImport("user32.dll", SetLastError=true)]
    public static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool CloseDesktop(IntPtr handle);
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
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 350

    $uia = 'NOT_AVAILABLE'
    try {
        Add-Type -AssemblyName UIAutomationClient
        $element = [System.Windows.Automation.AutomationElement]::FromHandle($button.Handle)
        if ($null -ne $element -and
            $element.Current.Name -eq 'SyntheticProbeButton') {
            $uia = 'PASS'
        } else {
            $uia = 'NO_MATCH'
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
    if ($uia -eq 'PASS' -and $pixel -eq 'PASS' -and $hasInputDesktop -and $interactive) {
        Write-Host 'GRAPHICS_SESSION_CLASS=INTERACTIVE_GRAPHICAL_DESKTOP_CANDIDATE'
    } else {
        Write-Host 'GRAPHICS_SESSION_CLASS=STRUCTURAL_UI_TESTS_ONLY_UNTIL_PROVEN'
    }
    Write-Host 'SAFE_PROBE=PASS (no production app, no external upload, no screenshot saved)'
} finally {
    if ($null -ne $graphics) { $graphics.Dispose() }
    if ($null -ne $bitmap) { $bitmap.Dispose() }
    if ($null -ne $form) { $form.Close(); $form.Dispose() }
    if ($inputDesktop -ne [IntPtr]::Zero) { [void][DesktopSessionProbe]::CloseDesktop($inputDesktop) }
}

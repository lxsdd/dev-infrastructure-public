# Windows Forms synthetic and future controlled UI geometry primitives.
# Pure in-process measurements: never captures/saves screenshots or user data.
#requires -Version 5.1
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Get-SafeDesktopLayoutDiagnostics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Windows.Forms.Form]$Window,
        [Parameter(Mandatory)][System.Windows.Forms.Control[]]$Controls
    )
    $issues = New-Object 'System.Collections.Generic.List[string]'
    if ($Window.IsDisposed -or -not $Window.Visible) {
        $issues.Add('WINDOW_NOT_VISIBLE')
    }
    $windowBox = $Window.Bounds
    if ($windowBox.Width -le 0 -or $windowBox.Height -le 0) {
        $issues.Add('WINDOW_INVALID_SIZE')
    }
    $screens = [System.Windows.Forms.Screen]::AllScreens
    $visible = $false
    foreach ($screen in $screens) {
        $intersection = [System.Drawing.Rectangle]::Intersect($windowBox, $screen.WorkingArea)
        if ($intersection.Width -ge 120 -and $intersection.Height -ge 80) {
            $visible = $true
            break
        }
    }
    if (-not $visible) { $issues.Add('WINDOW_OFFSCREEN') }
    foreach ($control in $Controls) {
        if ($null -eq $control) { $issues.Add('MISSING_CONTROL'); continue }
        $parent = $control.Parent
        if ($null -eq $parent -or -not $control.Visible) {
            $issues.Add('CONTROL_NOT_VISIBLE')
            continue
        }
        $client = $parent.ClientRectangle
        $bounds = $control.Bounds
        if ($bounds.Width -le 0 -or $bounds.Height -le 0) {
            $issues.Add('CONTROL_INVALID_SIZE')
            continue
        }
        if ($bounds.Left -lt $client.Left -or $bounds.Top -lt $client.Top -or
            $bounds.Right -gt $client.Right -or $bounds.Bottom -gt $client.Bottom) {
            $issues.Add('CONTROL_OUTSIDE_PARENT')
        }
        # Conservative no-wrap test: this is appropriate for Button only.
        # Arbitrary multi-line TextBlocks need framework-specific layout logic.
        if ($control -is [System.Windows.Forms.Button]) {
            $font = $control.Font
            $measure = [System.Windows.Forms.TextRenderer]::MeasureText(
                $control.Text, $font, [System.Drawing.Size]::Empty,
                [System.Windows.Forms.TextFormatFlags]::SingleLine)
            $availableWidth = $control.ClientSize.Width - 12
            if ($measure.Width -gt $availableWidth) {
                $issues.Add('BUTTON_TEXT_CLIPPED')
            }
        }
    }
    return [pscustomobject]@{
        Passed = ($issues.Count -eq 0)
        IssueCount = $issues.Count
        Issues = @($issues.ToArray())
        CheckedControls = $Controls.Length
    }
}

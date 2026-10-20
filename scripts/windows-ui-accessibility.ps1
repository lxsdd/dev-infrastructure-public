# Read-only UI Automation window geometry acceptance.
# No pointer changes, screenshots, event invocation, or private text logging.
# The owning test supplies its own window handle; no global window discovery.
#requires -Version 5.1
Set-StrictMode -Version Latest

function Test-WindowsUiAccessibility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][IntPtr]$WindowHandle,
        [string[]]$RequiredNames = @(),
        [string[]]$RequiredAutomationIds = @()
    )
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    if ($WindowHandle -eq [IntPtr]::Zero) {
        throw 'Production/synthetic test supplied an empty owned window handle.'
    }
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($WindowHandle)
    if ($null -eq $root) { throw 'No accessible UI root for owned window.' }
    $windowBounds = $root.Current.BoundingRectangle
    if ($windowBounds.Width -le 0 -or $windowBounds.Height -le 0) {
        throw 'Owned window has no measurable accessible geometry.'
    }
    $issues = New-Object 'System.Collections.Generic.List[string]'
    function Test-RequiredElement {
        param([object]$Property, [string]$Expected, [string]$Tag)
        if ([string]::IsNullOrWhiteSpace($Expected)) {
            $issues.Add(($Tag + '_EMPTY'))
            return
        }
        $condition = [System.Windows.Automation.PropertyCondition]::new($Property, $Expected)
        $matching = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
        if ($matching.Count -ne 1) {
            $issues.Add(($Tag + '_COUNT_NOT_ONE'))
            return
        }
        $element = $matching.Item(0)
        if ($element.Current.IsOffscreen) {
            $issues.Add(($Tag + '_OFFSCREEN'))
            return
        }
        $rect = $element.Current.BoundingRectangle
        if ($rect.Width -le 2 -or $rect.Height -le 2) {
            $issues.Add(($Tag + '_INVALID_BOUNDS'))
            return
        }
        $intersection = [System.Windows.Rect]::Intersect($windowBounds, $rect)
        if ($intersection.IsEmpty -or
            $intersection.Width -lt 2 -or $intersection.Height -lt 2) {
            $issues.Add(($Tag + '_OUTSIDE_WINDOW'))
        }
    }
    foreach ($name in $RequiredNames) {
        Test-RequiredElement -Property ([System.Windows.Automation.AutomationElement]::NameProperty) -Expected $name -Tag 'NAME'
    }
    foreach ($id in $RequiredAutomationIds) {
        Test-RequiredElement -Property ([System.Windows.Automation.AutomationElement]::AutomationIdProperty) -Expected $id -Tag 'AUTOMATION_ID'
    }
    return [pscustomobject]@{
        Passed = ($issues.Count -eq 0)
        IssueCount = $issues.Count
        Issues = @($issues.ToArray())
        ExpectedElements = $RequiredNames.Count + $RequiredAutomationIds.Count
    }
}

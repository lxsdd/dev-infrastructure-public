#requires -Version 5.1
# Public/synthetic host fixture only. No credentials, network, or audio writer.
[CmdletBinding()]
param([Parameter(Mandatory)][long]$ListHandle)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or $ListHandle -le 0 -or
   -not $env:RUNNER_TEMP) {
  throw 'UIA native content probe allowed only on an isolated GitHub runner.'
}
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
$element=[System.Windows.Automation.AutomationElement]::FromHandle(
  [IntPtr]::new($ListHandle))
if($null -eq $element) { throw 'No native candidate list UIA element.' }
$grid=$element.GetCurrentPattern(
  [System.Windows.Automation.GridPattern]::Pattern)
if($grid.RowCount -lt 3 -or $grid.RowCount -gt 1024 -or
   $grid.ColumnCount -lt 5) {
  throw "Native edition list has invalid UIA grid dimensions ($($grid.RowCount),$($grid.ColumnCount))."
}
$match=[System.Collections.Generic.HashSet[string]]::new(
  [System.StringComparer]::Ordinal)
for($i=0;$i -lt [Math]::Min(24,$grid.RowCount);$i++) {
  $field=$grid.GetItem($i,0).Current.Name
  if($field -eq 'Release Track 1' -or $field -eq 'Release Track 2') {
    $provider=$grid.GetItem($i,3).Current.Name
    $status=$grid.GetItem($i,4).Current.Name
    if($provider -cne 'Pasted: beatport' -or $status -cne 'Unmatched') {
      throw "Synthetic native release track provenance/status wrong for $field."
    }
    if(-not $match.Add($field)) {
      throw "Duplicate synthetic native release group: $field"
    }
  }
}
if($match.Count -ne 2) {
  throw "Synthetic native UIA display lacks both distinct blocked mix rows ($($match.Count))."
}
Write-Output 'HOST_UIA_SYNTHETIC_EDITION_FIELDS=PASS (2 tracks, pasted provenance, unmatched)'

# Fail-closed source/event policy for privileged native Discogs QA.
# This module is pure: no Discogs token, HTTP call, file writes or foobar
# operation. Protected environment permission is enforced by the CALLER job,
# before this second, independent runtime admission check is evaluated.
function Test-Fb2kAuthorizedDiscogsContext {
    [CmdletBinding()]
    param(
        [string]$EventName,
        [string]$Repository,
        [string]$Ref,
        [string]$EventPath,
        [string]$CheckedOutSha,
        [string]$WorkflowSha
    )
    $canonical = 'lxsdd/music-metadata-studio'
    $feature = 'feature/online-metadata-discovery-foundation-20261009'
    if($Repository -cne $canonical -or
       $CheckedOutSha -cnotmatch '^[a-f0-9]{40}$') { return $false }
    # Preserve previously approved manual protected environment behavior.
    if($EventName -ceq 'workflow_dispatch') {
        return $Ref -ceq ('refs/heads/' + $feature) -and
               $WorkflowSha -cmatch '^[a-f0-9]{40}$' -and
               $CheckedOutSha -ceq $WorkflowSha
    }
    # The only automatic live native consumer is the INTERNAL canonical
    # Studio PR #45, never fork PR, arbitrary same-repo PR, scheduled job,
    # push or pull_request_target. Never infer trust just from REF text.
    if($EventName -cne 'pull_request' -or
       $Ref -cne 'refs/pull/45/merge' -or
       [string]::IsNullOrWhiteSpace($EventPath) -or
       -not [IO.File]::Exists($EventPath)) { return $false }
    try {
        $info = [IO.FileInfo]::new($EventPath)
        if($info.Length -lt 2 -or $info.Length -gt 1048576) { return $false }
        $payload = Get-Content -LiteralPath $EventPath -Raw -Encoding UTF8 |
            ConvertFrom-Json -Depth 64 -ErrorAction Stop
        if($null -eq $payload -or $null -eq $payload.pull_request) {
            return $false
        }
        $pr = $payload.pull_request
        return [int]$payload.number -eq 45 -and
               [int]$pr.number -eq 45 -and
               [string]$pr.head.repo.full_name -ceq $canonical -and
               [string]$pr.head.ref -ceq $feature -and
               [string]$pr.head.sha -ceq $CheckedOutSha -and
               [string]$pr.base.repo.full_name -ceq $canonical -and
               [string]$pr.base.ref -ceq 'main'
    } catch {
        return $false
    }
}

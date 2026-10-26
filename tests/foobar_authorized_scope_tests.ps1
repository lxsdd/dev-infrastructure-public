#requires -Version 7.2
# Secret-free positive/negative authorization contract on disposable fixture JSON.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/../.github/actions/foobar-host-smoke/authorized-discogs-scope.ps1"
$repo='lxsdd/music-metadata-studio'
$feature='feature/online-metadata-discovery-foundation-20261009'
$sha='0123456789abcdef0123456789abcdef01234567'
$wrong='1123456789abcdef0123456789abcdef01234567'
$temp=Join-Path $env:RUNNER_TEMP ('studio-discogs-policy-'+[guid]::NewGuid().ToString('N'))
function Assert-Scope([bool]$expected,[string]$name,[hashtable]$args){
    $result=Test-Fb2kAuthorizedDiscogsContext @args
    if($result -ne $expected){throw "AUTHORIZED_SCOPE_CONTRACT=FAIL case=$name"}
}
function With-Changes([hashtable]$original,[hashtable]$changes) {
    $copy=$original.Clone()
    foreach($key in $changes.Keys){$copy[$key]=$changes[$key]}
    return $copy
}
function Copy-Event($fixture) {
    return ($fixture | ConvertTo-Json -Depth 32 | ConvertFrom-Json -Depth 32)
}
try {
  New-Item -Path $temp -ItemType Directory -ErrorAction Stop | Out-Null
  $path=Join-Path $temp 'pr.json'
  $base=@{EventName='pull_request';Repository=$repo;Ref='refs/pull/45/merge';
          EventPath=$path;CheckedOutSha=$sha;WorkflowSha=$wrong}
  $fixture=@{
      number=45
      pull_request=@{
          number=45
          head=@{sha=$sha;ref=$feature;repo=@{full_name=$repo}}
          base=@{ref='main';repo=@{full_name=$repo}}
      }
  }
  function Save-Event($body) {
      [IO.File]::WriteAllText($path,($body | ConvertTo-Json -Depth 32),
         [Text.UTF8Encoding]::new($false))
  }
  Save-Event $fixture
  Assert-Scope $true 'canonical-internal-pr' $base
  Assert-Scope $false 'not-PR45' (With-Changes $base @{Ref='refs/pull/46/merge'})
  Assert-Scope $false 'forked-repository' (With-Changes $base @{Repository='somebody/fork'})
  Assert-Scope $false 'push-forbidden' (With-Changes $base @{EventName='push'})
  Assert-Scope $false 'pull-request-target-forbidden' (With-Changes $base @{EventName='pull_request_target'})
  Assert-Scope $false 'incorrect-checked-out-sha' (With-Changes $base @{CheckedOutSha=$wrong})
  Assert-Scope $false 'missing-event-json' (With-Changes $base @{EventPath=(Join-Path $temp 'missing.json')})
  $mutations=@(
      @{name='foreign-pr-number';section='pull_request';field='number';value=46}
      @{name='foreign-top-number';section='root';field='number';value=46}
      @{name='fork-head';section='head';field='repo';value=@{full_name='fork/studio'}}
      @{name='wrong-source-branch';section='head';field='ref';value='feature/unreviewed'}
      @{name='head-commit-drift';section='head';field='sha';value=$wrong}
      @{name='fork-base';section='base';field='repo';value=@{full_name='fork/studio'}}
      @{name='foreign-base-branch';section='base';field='ref';value='develop'}
  )
  foreach($mutation in $mutations) {
      $f=Copy-Event $fixture
      $target=switch($mutation.section){
          'root' {$f}
          'head' {$f.pull_request.head}
          'base' {$f.pull_request.base}
          default {$f.pull_request}
      }
      $target.($mutation.field)=$mutation.value
      Save-Event $f
      Assert-Scope $false $mutation.name $base
  }
  [IO.File]::WriteAllText($path,'{invalid', [Text.UTF8Encoding]::new($false))
  Assert-Scope $false 'malformed-json' $base
  $manual=@{EventName='workflow_dispatch';Repository=$repo;
            Ref=('refs/heads/'+$feature);EventPath='';CheckedOutSha=$sha;WorkflowSha=$sha}
  Assert-Scope $true 'original-manual-protected-dispatch' $manual
  Assert-Scope $false 'manual-wrong-branch' (With-Changes $manual @{Ref='refs/heads/main'})
  Assert-Scope $false 'manual-sha-drift' (With-Changes $manual @{WorkflowSha=$wrong})
  Assert-Scope $false 'manual-foreign-repo' (With-Changes $manual @{Repository='other/repo'})
  Write-Host 'AUTHORIZED_STUDIO_PR_NATIVE_SCOPE_POLICY=PASS (positive and negative real event fixtures, manual preserved)'
} finally {
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

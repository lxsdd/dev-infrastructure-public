"""Static mutation checks for the public reusable foobar host action.
The real PowerShell helper is also tested with valid/invalid event fixtures
on a secret-free Windows runner. No real provider credential is ever used.
"""
from pathlib import Path
BASE=Path(__file__).resolve().parents[1]
ACTION=(BASE/".github/actions/foobar-host-smoke/action.yml").read_text(encoding="utf-8")
HOST=(BASE/".github/actions/foobar-host-smoke/host-smoke.ps1").read_text(encoding="utf-8")
SCOPE=(BASE/".github/actions/foobar-host-smoke/authorized-discogs-scope.ps1").read_text(encoding="utf-8")
WORKFLOW=(BASE/".github/workflows/foobar-host-smoke.yml").read_text(encoding="utf-8")

def violations(action:str,host:str,scope:str,workflow:str)->list[str]:
    bad=[]
    required_scope=[
        "$EventName -cne 'pull_request'",
        "$Ref -cne 'refs/pull/45/merge'",
        "[int]$payload.number -eq 45",
        "[int]$pr.number -eq 45",
        "[string]$pr.head.repo.full_name -ceq $canonical",
        "[string]$pr.head.ref -ceq $feature",
        "[string]$pr.head.sha -ceq $CheckedOutSha",
        "[string]$pr.base.repo.full_name -ceq $canonical",
        "[string]$pr.base.ref -ceq 'main'",
        "$EventName -ceq 'workflow_dispatch'",
        "$WorkflowSha -cmatch '^[a-f0-9]{40}$'",
        "$CheckedOutSha -ceq $WorkflowSha",
        "ConvertFrom-Json -Depth 64 -ErrorAction Stop",
    ]
    for x in required_scope:
        if x not in scope: bad.append("missing authentic runtime authorization: "+x)
    for x in ("Test-Fb2kAuthorizedDiscogsContext", "authorized-discogs-scope.ps1",
              "-CheckedOutSha $checkedOutSha", "-WorkflowSha $env:GITHUB_SHA",
              "-EventPath $env:GITHUB_EVENT_PATH", "-Repository $env:GITHUB_REPOSITORY",
              "@('38012673','37332711','36397609','36819730')",
              "[Environment]::SetEnvironmentVariable('FB2K_DISCOGS_QA_TOKEN',$null,'Process')"):
        if x not in host: bad.append("production host guard disconnected: "+x)
    if "authorized-discogs-probe" not in action or "FB2K_AUTHORIZED_DISCOGS_PROBE" not in action:
        bad.append("protected control input missing")
    if "uses: actions/upload-artifact@" in workflow or "secrets." in workflow:
        bad.append("secret/published artifact introduced into public fixture workflow")
    if "foobar_authorized_scope_tests.ps1" not in workflow or "foobar_host_policy_tests.py" not in workflow:
        bad.append("negative test not part of the new action's CI")
    if "pull_request_target:" in workflow:
        bad.append("untrusted target PR workflow introduced")
    return bad

def main():
    assert not violations(ACTION,HOST,SCOPE,WORKFLOW),violations(ACTION,HOST,SCOPE,WORKFLOW)
    for s in (
        SCOPE.replace("$Ref -cne 'refs/pull/45/merge'", "$Ref -cne 'refs/pull/999/merge'",1),
        SCOPE.replace("[string]$pr.head.sha -ceq $CheckedOutSha","$true",1),
        SCOPE.replace("[string]$pr.base.repo.full_name -ceq $canonical","$true",1),
        SCOPE.replace("$EventName -cne 'pull_request'","$EventName -cne 'pull_request_target'",1),
        SCOPE.replace("$CheckedOutSha -ceq $WorkflowSha","$true",1),
    ):
        assert violations(ACTION,HOST,s,WORKFLOW),"tampered secret boundary escaped"
    for h in (
        HOST.replace("-CheckedOutSha $checkedOutSha","-CheckedOutSha $env:GITHUB_SHA",1),
        HOST.replace("-EventPath $env:GITHUB_EVENT_PATH","-EventPath ''",1),
    ):
        assert violations(ACTION,h,SCOPE,WORKFLOW)
    print("PASS: no secret upload, real PR payload/source SHA binding, manual preserve and negative mutations")

if __name__=="__main__":
    main()

#!/usr/bin/env python3
"""Second independent history scan; never print detected credentials or matching lines."""
import collections
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPOS={"foo_dj_library_bridge","foobar2000_component_template","rekordbox-mytag-sync",
"music-metadata-studio","dj-library-public","foo_smart_tempo-public","gmscore-cast",
"dj-library","foo_discogger","dev-infrastructure-public"}
VERSION="8.30.1"
SHA256="551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"

def call(argv,**opts):
    return subprocess.run(argv,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**opts)

def audit(repo):
    if repo not in REPOS:raise RuntimeError("Unknown public repo")
    with tempfile.TemporaryDirectory(prefix="gitleaks-audit-") as td:
        dir=Path(td)
        url="https://github.com/gitleaks/gitleaks/releases/download/v"+VERSION+"/gitleaks_"+VERSION+"_linux_x64.tar.gz"
        archive=dir/"gitleaks.tar.gz"
        r=call(["curl","--fail","--silent","--show-error","--location","--retry","3","--output",str(archive),url],timeout=180)
        if r.returncode:raise RuntimeError("Pinned Gitleaks download unavailable")
        actual=hashlib.sha256(archive.read_bytes()).hexdigest()
        if actual!=SHA256:raise RuntimeError("Pinned Gitleaks checksum mismatch")
        unpack=call(["tar","-xzf",str(archive),"-C",str(dir),"gitleaks"],timeout=60)
        if unpack.returncode:raise RuntimeError("Gitleaks extraction failed")
        executable=str(dir/"gitleaks")
        mirror=str(dir/"source.git")
        r=call(["git","clone","--mirror","--quiet","https://github.com/lxsdd/"+repo+".git",mirror],timeout=1000)
        if r.returncode:raise RuntimeError("Public clone failed")
        r=call(["git","fetch","--quiet","origin","+refs/pull/*/head:refs/pull/*/head"],cwd=mirror,timeout=180)
        if r.returncode:raise RuntimeError("Pull-request refs fetch failed")
        report=dir/"results.json"
        r=call([executable,"git","--redact=100","--log-opts=--all","--report-format=json","--report-path="+str(report),mirror],timeout=2200)
        if r.returncode not in (0,1):raise RuntimeError("Gitleaks process failed")
        if not report.is_file():raise RuntimeError("No Gitleaks machine report")
        matches=json.loads(report.read_text("utf-8"))
        if not isinstance(matches,list):raise RuntimeError("Unexpected Gitleaks report shape")
        rules=collections.Counter(str(x.get("RuleID","unknown")) for x in matches)
        # No matching line, file name, author, secret or match is ever printed or retained.
        return {"repository":repo,"version":VERSION,"method":"gitleaks git --all",
                "findings":len(matches),"rules":dict(sorted(rules.items())),"completed":True,
                "included_pr_refs":True}

if __name__=="__main__":
    try:
        print("INDEPENDENT_SECRET_AUDIT_JSON="+json.dumps(audit(sys.argv[1]),sort_keys=True,separators=(",",":")))
    except Exception as e:
        print("INDEPENDENT_SECRET_AUDIT_ERROR="+type(e).__name__+":"+str(e).splitlines()[0][:110])
        raise SystemExit(2)

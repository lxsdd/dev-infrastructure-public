#!/usr/bin/env python3
"""Public-safe triage: never print access key values, local paths, or source snippets."""
import collections
import hashlib
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

SPECS={
    "google_api_key":rb"\bAIza[0-9A-Za-z_-]{35}\b",
    "aws_access_key":rb"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b",
    "assignment":rb"(?i)\b(?:client[_-]?secret|access[_-]?token|api[_-]?key|password|passwd|consumer[_-]?secret)\s*[:=]\s*['\"]?[A-Za-z0-9_./+=-]{20,}",
}
PATTERNS={k:re.compile(v) for k,v in SPECS.items()}
PRIVATE_PATH=re.compile(rb"(?i)(?:[A-Z]:\\Users\\([^\\\r\n]{2,80})\\|[A-Z]:\\(?:Music|PIONEER)\\|/home/([^/\s]{2,60})/|/Users/([^/\s]{2,60})/)")
GENERIC={"user","username","test","tester","example","sample","default","public","selftest","yourname","name","runner","administrator"}

def run(args,cwd=None):
    return subprocess.run(args,cwd=cwd,check=True,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL).stdout

def hexid(s):
    return hashlib.sha256(s).hexdigest()[:18]

def analyze(root,include_history):
    if include_history:
        target=Path(root)/"history.git"
        subprocess.run(["git","clone","--mirror","--quiet","https://github.com/lxsdd/gmscore-cast.git",str(target)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=1000)
        run(["git","fetch","--quiet","origin","+refs/pull/*/head:refs/pull/*/head"],target)
        objects=run(["git","cat-file","--batch-all-objects","--batch-check=%(objectname) %(objecttype) %(objectsize)"],target).decode().splitlines()
        rev=run(["git","rev-list","--objects","--all"],target).decode("utf-8","replace").splitlines()
        names={r.split(" ",1)[0]:r.split(" ",1)[1] for r in rev if " " in r}
        main_tree=run(["git","ls-tree","-r","--format=%(objectname)","refs/heads/main"],target).decode().splitlines()
        main_blobs=set(main_tree)
    else:
        target=Path(root)/"upstream"
        subprocess.run(["git","clone","--depth=1","--quiet","https://github.com/MorpheApp/MicroG-RE.git",str(target)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=1000)
        objects=run(["git","ls-tree","-r","--long","HEAD"],target).decode().splitlines()
        entries=[(r.split()[2],int(r.split()[3]),r.split("\t",1)[1]) for r in objects if r.split()[1]=="blob" and r.split()[3].isdigit()]
        names={s:n for s,z,n in entries}
        objects=[s+" blob "+str(z) for s,z,n in entries]
        main_blobs=set(names)
    fp=collections.defaultdict(set)
    hist=collections.defaultdict(lambda:collections.Counter())
    path_counts=collections.Counter()
    test_path=collections.Counter()
    with subprocess.Popen(["git","cat-file","--batch"],cwd=target,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,bufsize=0) as cat:
        for entry in objects:
            sha,typ,size=entry.split()
            if typ!="blob" or int(size)>256*1024*1024: continue
            cat.stdin.write((sha+"\n").encode())
            meta=cat.stdout.readline().decode().split()
            if len(meta)!=3 or meta[1]!="blob": raise RuntimeError("Unexpected historical Git blob")
            remain=int(meta[2]); parts=[]
            while remain:
                part=cat.stdout.read(min(1024*1024,remain))
                if not part: raise RuntimeError("Short Git stream")
                parts.append(part); remain-=len(part)
            content=b"".join(parts)
            if cat.stdout.read(1)!=b"\n":raise RuntimeError("Invalid object delimiter")
            path=names.get(sha,"")
            is_main=sha in main_blobs
            for kind,p in PATTERNS.items():
                for m in p.finditer(content):
                    digest=hexid(m.group(0))
                    fp[kind].add(digest)
                    hist[kind][digest]+=1
                    if is_main:path_counts[kind+"_current"]+=1
                    if any(x in path.lower() for x in ("test/","tests/","sample","example","fixture","mock")):
                        test_path[kind]+=1
            for m in PRIVATE_PATH.finditer(content):
                username=next((g for g in m.groups() if g),b"")
                is_generic=username.decode("utf-8","ignore").lower() in GENERIC
                path_counts["path_generic" if is_generic else "path_non_generic"]+=1
        cat.stdin.close()
    return {k:{"unique_identifiers":len(v),"occurrences":sum(hist[k].values()),"existing_at_head_occurrences":path_counts[k+"_current"],"test_or_sample_path_occurrences":test_path[k],"identifier_hashes":sorted(v)[:30]} for k,v in fp.items()},dict(path_counts)

def main():
    with tempfile.TemporaryDirectory() as work:
        own,paths=analyze(work,True)
        upstream,_=analyze(work,False)
    output={}
    for kind,data in own.items():
        upstream_ids=set(upstream.get(kind,{}).get("identifier_hashes",[]))
        candidates=set(data["identifier_hashes"])
        output[kind]={
            "unique_identifiers":data["unique_identifiers"],
            "historical_occurrences":data["occurrences"],
            "current_head_occurrences":data["existing_at_head_occurrences"],
            "test_path_occurrences":data["test_or_sample_path_occurrences"],
            "known_id_prefixes_in_parent_head":len(candidates & upstream_ids),
            "reported_identifier_prefixes":len(candidates)
        }
    print("GMSCORE_TRIAGE_JSON="+json.dumps({"repository":"gmscore-cast","credentials":output,"path_pattern_occurrences":paths,"comparison":"MorpheApp/MicroG-RE HEAD only; no raw secrets printed"},sort_keys=True,separators=(",",":")))

if __name__=="__main__":
    try:main()
    except Exception as e:
        print("TRIAGE_ERROR="+type(e).__name__)
        raise SystemExit(2)

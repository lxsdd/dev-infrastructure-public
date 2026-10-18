#!/usr/bin/env python3
"""Read-only, synthetic-safe scan of reachable public Git history. Never print secret values."""
import collections
import hashlib
import json
import os
import re
import subprocess
import tempfile
import time
from pathlib import Path

REPOS = (
 "foo_dj_library_bridge", "foobar2000_component_template",
 "rekordbox-mytag-sync", "music-metadata-studio", "dj-library-public",
 "foo_smart_tempo-public", "gmscore-cast", "dj-library",
 "foo_discogger", "dev-infrastructure-public"
)
MEDIA = re.compile(r"\.(?:mp3|flac|wav|aiff|m4a|ogg|opus|wma|mp4|mkv|mov|jpeg|jpg|png|heic|sqlite|sqlite3|db|edb|mdb|accdb|p12|pfx|jks|keystore)$", re.I)
PRIVATE_PATH = re.compile(r"(^|/)(?:\.env(?:\..+)?|id_rsa|id_ed25519|.*(?:password|credential|secret|token|private[_-]?key).*)$", re.I)
BINARY = re.compile(r"\.(?:dll|exe|lib|a|pdb|so|jar|aar|apk|aab|zip|7z|rar|fb2k-component|onnx|ttf|otf|bin)$", re.I)
LICENSE = re.compile(r"(^|/)(?:licen[cs]e(?:[._-].*)?|copying(?:[._-].*)?|notice(?:[._-].*)?|third[_-]party[_-]notices(?:[._-].*)?)$", re.I)
SIGNATURES = {
 "github_credential": re.compile(rb"(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{50,})"),
 "aws_access_key": re.compile(rb"(?:AKIA|ASIA)[0-9A-Z]{16}"),
 "private_key_block": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"),
 "openai_secret_key": re.compile(rb"sk-(?:proj-)?[A-Za-z0-9_-]{24,}"),
 "slack_token": re.compile(rb"xox[baprs]-[A-Za-z0-9-]{20,}"),
 "google_api_key": re.compile(rb"AIza[0-9A-Za-z_-]{35}")
}
# Generic assignments are candidates, not confirmed credentials.
ASSIGNMENT = re.compile(rb"(?im)\b(?:api[_-]?key|access[_-]?token|client[_-]?secret|password|consumer[_-]?secret|auth[_-]?token)\b\s*[:=]\s*['\"]([^'\"\r\n]{9,160})['\"]")
PLACEHOLDER = re.compile(rb"(?i)(?:example|placeholder|dummy|changeme|fake|test[-_]?only|your[_-]|<|%|variable|token[_-]?name|env|sample|synthetic)")
PERSONAL = re.compile(rb"(?i)(?:[A-Z]:\\Users\\|/home/[^/\s]{3,40}/|[A-Z]:\\Music\\|[A-Z]:\\PIONEER\\|catalog-v0\.4\.sqlite)")
LIMIT = 25 * 1024 * 1024

def git(*args, cwd=None, timeout=1200):
 return subprocess.check_output(["git", *args], cwd=cwd, stderr=subprocess.PIPE, timeout=timeout)
def redacted_hit(where, typ, blob):
 return {"path":where[:160], "kind":typ, "blob":blob[:12]}
def scan_repo(name, folder):
 url=f"https://github.com/lxsdd/{name}.git"
 repo=folder/name
 subprocess.run(["git","clone","--mirror","--quiet",url,str(repo)],check=True,timeout=900)
 # Also include refs reachable solely via pull requests, when advertised.
 pull_error=None
 try:
  subprocess.run(["git","fetch","--quiet","origin","+refs/pull/*/head:refs/audit/pull/*"],cwd=repo,check=True,timeout=300,capture_output=True)
 except Exception as exc: pull_error=type(exc).__name__
 revs=git("rev-list","--objects","--all",cwd=repo,timeout=400).decode("utf8","replace").splitlines()
 paths=collections.defaultdict(set)
 for item in revs:
  sha,_,p=item.partition(" ")
  if p: paths[sha].add(p)
 object_ids=list(paths)
 # Include blobs without a path, e.g. deeply detached trees, via batch check.
 seen=set()
 counts=collections.Counter()
 alerts=[]
 history_paths=set()
 license_paths=set()
 size_skipped=[]
 start=time.monotonic()
 proc=subprocess.Popen(["git","cat-file","--batch"],cwd=repo,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,bufsize=0)
 try:
  for sha in object_ids:
   proc.stdin.write((sha+"\n").encode())
   hdr=proc.stdout.readline().decode("ascii","replace").strip().split()
   if len(hdr)<3 or hdr[1]!="blob":
    if len(hdr)>=3 and hdr[2].isdigit():
     length=int(hdr[2])
     left=length
     while left:
      n=len(proc.stdout.read(min(left,1024*1024)))
      if not n: raise RuntimeError("short object")
      left-=n
     proc.stdout.read(1)
    continue
   size=int(hdr[2]); counts["blobs"]+=1; counts["bytes"]+=size
   pths=paths[sha]
   history_paths.update(pths)
   for p in pths:
    if LICENSE.search(p): license_paths.add(p)
    if MEDIA.search(p): counts["media_or_database_paths"]+=1
    if PRIVATE_PATH.search(p): counts["sensitive_named_paths"]+=1
    if BINARY.search(p): counts["binary_paths"]+=1
   if size>LIMIT:
    size_skipped.append(redacted_hit(next(iter(pths),"<unknown>"),"oversize_blob",sha))
    counts["oversize_blobs"]+=1
    left=size
    while left:
     n=len(proc.stdout.read(min(left,1024*1024)))
     if not n: raise RuntimeError("short object")
     left-=n
    proc.stdout.read(1)
    continue
   content=proc.stdout.read(size)
   if len(content)!=size: raise RuntimeError("short blob")
   proc.stdout.read(1)
   if b"\x00" in content[:4096]:
    counts["binary_content_blobs"]+=1
    # Binary contents need format-specific inspection, not naive UTF-8 screening.
    continue
   counts["text_blobs"]+=1
   scan_paths=list(pths)[:3] or ["<unknown>"]
   for label,pattern in SIGNATURES.items():
    if pattern.search(content):
     counts["pattern_"+label]+=1
     if len(alerts)<150: alerts.append(redacted_hit(scan_paths[0],label,sha))
   for m in ASSIGNMENT.finditer(content):
    if not PLACEHOLDER.search(m.group(1)):
     counts["potential_embedded_credential"]+=1
     if len(alerts)<150: alerts.append(redacted_hit(scan_paths[0],"potential_embedded_credential",sha))
     if counts["potential_embedded_credential"]>=100: break
   if PERSONAL.search(content):
    counts["path_reference_hits"]+=1
    if len(alerts)<150: alerts.append(redacted_hit(scan_paths[0],"personal_path_reference",sha))
 finally:
  proc.stdin.close()
  proc.stdout.close()
  proc.wait(timeout=120)
 # Audit type of HEAD files and license indicators; all historical blob content was inspected once.
 return {
  "repository":name,"git_reachable_objects":len(revs),"unique_named_objects":len(object_ids),
  "historical_paths":len(history_paths),"head_license_candidates":len(license_paths),
  "license_paths_sample":sorted(license_paths)[:18],
  "stats":dict(counts),"alerts_redacted":alerts[:60],
  "oversize_examples":size_skipped[:12],
  "pr_refs_fetch_error":pull_error,
  "audit_seconds":round(time.monotonic()-start,1)
 }
def main():
 reports=[]
 with tempfile.TemporaryDirectory() as dir:
  for name in REPOS:
   print("START",name,flush=True)
   try: report=scan_repo(name,Path(dir))
   except Exception as e:
    report={"repository":name,"audit_error":type(e).__name__+":"+str(e)[:140]}
   reports.append(report)
   print("AUDIT_REPORT "+json.dumps(report,ensure_ascii=True,separators=(",",":")),flush=True)
 print("AUDIT_SUMMARY "+json.dumps({
  "repositories":len(reports),"completed":sum("stats" in x for x in reports),
  "errors":[x for x in reports if "audit_error" in x],
  "total_history_blobs":sum(x.get("stats",{}).get("blobs",0) for x in reports),
  "total_credentials_detected":sum(sum(v for k,v in x.get("stats",{}).items() if k.startswith("pattern_") or k=="potential_embedded_credential") for x in reports)
 },separators=(",",":")),flush=True)
 if any("audit_error" in x for x in reports): raise SystemExit(2)
if __name__=="__main__": main()

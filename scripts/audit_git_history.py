#!/usr/bin/env python3
"""Read-only scan of all locally obtainable Git blobs; never output secret values."""
import base64
import collections
import gzip
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

REPO = sys.argv[1] if len(sys.argv) > 1 else ""
ALLOW = {
    "foo_dj_library_bridge", "foobar2000_component_template",
    "rekordbox-mytag-sync", "music-metadata-studio",
    "dj-library-public", "foo_smart_tempo-public", "gmscore-cast",
    "dj-library", "foo_discogger", "dev-infrastructure-public", "foo_metadata_isolation-public",
}
if REPO not in ALLOW:
    raise SystemExit("Repository must be a known public audit target")

PATTERNS = {
    "github_credential": rb"\b(?:ghp_|gho_|ghu_|ghs_|ghr_)[A-Za-z0-9_]{20,}\b|\bgithub_pat_[A-Za-z0-9_]{30,}\b",
    "cloud_credential": rb"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b|\bAIza[0-9A-Za-z_-]{35}\b",
    "service_credential": rb"\bxox[baprs]-[0-9A-Za-z-]{20,}\b|\bsk-(?:proj-)?[A-Za-z0-9_-]{24,}\b",
    "private_key_material": rb"-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----",
    "auth_header_secret": rb"(?i)\b(?:Authorization:\s*(?:Basic|Bearer)\s+)[A-Za-z0-9_\-./+=]{22,}",
    "assigned_credential": rb"(?i)\b(?:client[_-]?secret|access[_-]?token|api[_-]?key|password|passwd|consumer[_-]?secret)\s*[:=]\s*['\"]?[A-Za-z0-9_./+=-]{20,}",
    "private_media_path": rb"(?i)(?:[A-Z]:\\(?:Users\\[^\\\r\n]{2,80}\\|Music\\|PIONEER\\)|/home/[^/\r\n ]{2,60}/|/Users/[^/\r\n ]{2,60}/)",
}
REGEX = {k: re.compile(v) for k,v in PATTERNS.items()}
BIN_EXT = {".db",".edb",".sqlite",".sqlite3",".mp3",".flac",".wav",".m4a",".aac",".ogg",".mp4",".p12",".pfx",".pem",".key",".jks",".keystore",".kdbx"}
ART_EXT = {".dll",".exe",".fb2k-component",".zip",".7z",".jar",".aar",".apk",".lib",".pdb"}
ARCHIVE_LIMIT = 64 * 1024 * 1024
BYTES_LIMIT = 256 * 1024 * 1024

def run(*args, cwd=None, check=True):
    p = subprocess.run(args, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if check and p.returncode:
        raise RuntimeError("Git command failed (exit " + str(p.returncode) + "): " + str(args[:2]))
    return p

def identifier(value):
    return hashlib.sha256(value.encode("utf-8", "surrogateescape")).hexdigest()[:12]

def inspect_data(data, name, hit, depth=0):
    data = bytes(data)
    for kind, pattern in REGEX.items():
        if pattern.search(data):
            hit.add(kind)
    suffix = Path(name.lower()).suffix
    if data.startswith(b"SQLite format 3\x00"):
        hit.add("sqlite_database")
    if data.startswith(b"ID3") or data.startswith(b"fLaC"):
        hit.add("media_data")
    if suffix in BIN_EXT:
        hit.add("private_data_extension")
    if suffix in ART_EXT:
        hit.add("binary_distribution")
    if depth >= 2 or len(data) > ARCHIVE_LIMIT:
        return
    if suffix == ".b64" and len(data) < ARCHIVE_LIMIT:
        try:
            decoded = base64.b64decode(re.sub(rb"\s+", b"", data), validate=True)
            if decoded and len(decoded) <= ARCHIVE_LIMIT:
                inspect_data(decoded, name[:-4], hit, depth+1)
        except (ValueError, base64.binascii.Error):
            pass
    if data.startswith(b"PK\x03\x04") or data.startswith(b"PK\x05\x06"):
        try:
            with zipfile.ZipFile(io.BytesIO(data)) as z:
                for item in z.infolist()[:1000]:
                    if item.is_dir():
                        continue
                    if item.file_size > ARCHIVE_LIMIT:
                        hit.add("oversized_archive_member")
                        continue
                    try:
                        chunk = z.read(item, pwd=None)
                        if len(chunk) <= ARCHIVE_LIMIT:
                            inspect_data(chunk, item.filename, hit, depth+1)
                    except (OSError, RuntimeError, ValueError, NotImplementedError):
                        hit.add("unreadable_archive_member")
        except (OSError, ValueError, zipfile.BadZipFile):
            hit.add("malformed_archive")
    elif data.startswith(b"\x1f\x8b"):
        try:
            with gzip.GzipFile(fileobj=io.BytesIO(data)) as f:
                unpacked = f.read(ARCHIVE_LIMIT + 1)
            if len(unpacked) > ARCHIVE_LIMIT:
                hit.add("oversized_gzip_member")
            else:
                inspect_data(unpacked, name.removesuffix(".gz"), hit, depth+1)
        except (OSError, EOFError, ValueError):
            hit.add("unreadable_gzip")

def audit(root):
    # --mirror gets full reachable Git history/heads/tags. Fetch PR heads separately.
    mirror = Path(root) / "repository.git"
    subprocess.run(
        ["git", "clone", "--mirror", "--quiet", "https://github.com/lxsdd/" + REPO + ".git", str(mirror)],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        timeout=1000,
    )
    extra = run("git","fetch","--quiet","origin","+refs/pull/*/head:refs/pull/*/head",
                cwd=mirror,check=False)
    pr_refs = extra.returncode == 0
    refs = run("git", "for-each-ref", "--format=%(refname)", cwd=mirror).stdout.splitlines()
    commit_count = int(run("git", "rev-list", "--all", "--count", cwd=mirror).stdout.strip())
    rev = run("git","rev-list","--objects","--all",cwd=mirror).stdout.splitlines()
    paths = {}
    for row in rev:
        if " " in row:
            sha, filename = row.split(" ", 1)
            paths.setdefault(sha, filename)
    entries = run("git","cat-file","--batch-all-objects","--batch-check=%(objectname) %(objecttype) %(objectsize)",cwd=mirror).stdout.splitlines()
    objects = [(s,int(n)) for line in entries for s,t,n in [line.split(" ")] if t=="blob"]
    counts=collections.Counter()
    evidence=collections.defaultdict(list)
    lic=collections.Counter()
    total=0
    bytes_total=0
    unscanned=0
    with subprocess.Popen(
        ["git","cat-file","--batch"],cwd=mirror,
        stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,bufsize=0
    ) as cat:
        for sha,declared_size in objects:
            cat.stdin.write((sha+"\n").encode("ascii"))
            header=cat.stdout.readline().decode("ascii","replace").strip().split()
            if len(header)!=3 or header[0]!=sha or header[1]!="blob":
                raise RuntimeError("Unexpected cat-file blob response")
            size=int(header[2])
            if size!=declared_size:
                raise RuntimeError("Inconsistent Git blob length")
            pieces=[]
            remaining=size
            while remaining:
                chunk=cat.stdout.read(min(remaining, 1024*1024))
                if not chunk:
                    raise RuntimeError("Incomplete historical blob read")
                pieces.append(chunk)
                remaining-=len(chunk)
            raw=b"".join(pieces)
            delim=cat.stdout.read(1)
            if delim!=b"\n":
                raise RuntimeError("Incomplete historical blob delimiter")
            bytes_total+=size
            total+=1
            path=paths.get(sha,sha)
            flags=set()
            if size>BYTES_LIMIT:
                unscanned+=1
                flags.add("oversized_blob")
            else:
                inspect_data(raw,path,flags)
                basename=Path(path).name.lower()
                if basename.startswith(("license","licence","copying","notice")):
                    lic["license_named_files"]+=1
                if b"SPDX-License-Identifier:" in raw:
                    lic["files_with_spdx"]+=1
                if path.startswith(("vendor/","third_party/","3rdparty/","external/")):
                    lic["vendor_blobs"]+=1
                if re.search(rb"(?i)(?:copyright\s*(?:\(|\xC2\xA9)|all rights reserved)",raw[:8192]):
                    lic["copyright_notice_blobs"]+=1
            for flag in flags:
                counts[flag]+=1
                if len(evidence[flag])<12:
                    # Path itself may identify a user or contain credentials. Never log it.
                    evidence[flag].append({"path_hash":identifier(path),"blob":sha[:12]})
        cat.stdin.close()
        if cat.wait()!=0:
            raise RuntimeError("Git cat-file failed")
    return {
        "repository": REPO, "status":"completed",
        "git_refs":len(refs), "commits":commit_count,
        "unique_historical_blobs":total, "historical_blob_bytes":bytes_total,
        "all_visible_blobs_read":unscanned==0,
        "oversized_blob_count":unscanned, "pr_refs_fetched":pr_refs,
        "hits":dict(sorted(counts.items())),
        "evidence":dict(sorted(evidence.items())),
        "license_indicators":dict(lic),
        "limitations":[
            "Reachable advertised Git refs and mirrored objects only",
            "Unreachable/deleted GitHub objects and expired action logs unavailable",
            "Third-party license provenance cannot be conclusively established by regex",
            "Heuristic secret detection is not proof that every credential is absent"
        ]
    }

def main():
    with tempfile.TemporaryDirectory(prefix="repo-history-audit-") as folder:
        report=audit(folder)
    print("AUDIT_RESULT_JSON="+json.dumps(report,sort_keys=True,separators=(",",":")))
    summary=os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary,"a",encoding="utf-8") as f:
            f.write("### History audit: "+REPO+"\n\n")
            f.write("Git refs: "+str(report["git_refs"])+", commits: "+str(report["commits"])+", historical blobs: "+str(report["unique_historical_blobs"])+"\n\n")
            f.write("Redacted categories: "+json.dumps(report["hits"],sort_keys=True)+"\n\n")
            f.write("Only non-secret counts and hashes are reported.\n")

if __name__=="__main__":
    try:
        main()
    except Exception as exc:
        print("AUDIT_ERROR="+type(exc).__name__+":"+str(exc).splitlines()[0][:150])
        raise SystemExit(2)

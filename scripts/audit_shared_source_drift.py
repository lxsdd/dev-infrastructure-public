#!/usr/bin/env python3
"""Read-only verification that public shared-source copies still match owner Git blobs.

Uses only anonymous HTTPS GETs to raw.githubusercontent.com on public main
branches. No token, clone, SDK, binary build or user data is needed.
"""
import argparse
import hashlib
import json
import re
import sys
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import urlopen

REGISTRY = Path(__file__).resolve().parents[1] / "contracts/shared-source-registry.json"
MIN_CONSUMERS = {
    "publication-guard": 3,
    "wpf-touchpad-router": 2,
    "foobar-component-verifier": 2,
    "bridge-v3-cue-golden": 1,
}
REPO_RE = re.compile(r"^lxsdd/[a-zA-Z0-9_.-]+$")
PATH_RE = re.compile(r"^[a-zA-Z0-9_.\-/]+$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")


def git_blob_sha1(data):
    prefix = b"blob " + str(len(data)).encode("ascii") + b"\0"
    return hashlib.sha1(prefix + data).hexdigest()


def validate_registry(registry):
    if not isinstance(registry, dict) or registry.get("schema_version") != 1:
        raise ValueError("unknown shared source registry schema")
    contracts = registry.get("contracts")
    if not isinstance(contracts, list) or len(contracts) != len(MIN_CONSUMERS):
        raise ValueError("missing or duplicated required contracts")
    identifiers = set()
    global_targets = set()
    for entry in contracts:
        if not isinstance(entry, dict) or not isinstance(entry.get("id"), str):
            raise ValueError("invalid contract")
        ident = entry["id"]
        if ident in identifiers or ident not in MIN_CONSUMERS:
            raise ValueError("duplicate or unexpected contract: " + ident)
        identifiers.add(ident)
        if not isinstance(entry.get("sha1"), str) or not SHA_RE.fullmatch(entry["sha1"]):
            raise ValueError("invalid canonical Git blob pin: " + ident)
        consumers = entry.get("consumers")
        if not isinstance(consumers, list) or len(consumers) < MIN_CONSUMERS[ident]:
            raise ValueError("lost public consumers of: " + ident)
        for role, target in [("owner", entry.get("owner"))] + [
            ("consumer", v) for v in consumers
        ]:
            if not isinstance(target, dict):
                raise ValueError("invalid source target")
            repo, path = target.get("repo"), target.get("path")
            if not isinstance(repo, str) or not REPO_RE.fullmatch(repo):
                raise ValueError("non-approved public repository in " + ident)
            if (not isinstance(path, str) or not PATH_RE.fullmatch(path)
                    or path.startswith("/") or "\\" in path
                    or any(part in ("", ".", "..") for part in path.split("/"))):
                raise ValueError("unsafe repository path in " + ident)
            key = (repo, path)
            if key in global_targets:
                raise ValueError("same source target registered more than once")
            global_targets.add(key)
    if identifiers != set(MIN_CONSUMERS):
        raise ValueError("incomplete canonical contracts")


def check_registry(registry, fetch):
    validate_registry(registry)
    checked = 0
    errors = []
    for contract in registry["contracts"]:
        for target in [contract["owner"], *contract["consumers"]]:
            repo, path = target["repo"], target["path"]
            checked += 1
            try:
                data = fetch(repo, path)
                if not isinstance(data, bytes):
                    raise TypeError("fetcher did not return bytes")
                actual = git_blob_sha1(data)
                if actual != contract["sha1"]:
                    errors.append(
                        f"{contract['id']}: SOURCE_DRIFT {repo}/{path}: {actual}"
                    )
            except (OSError, ValueError, TypeError, HTTPError, URLError) as exc:
                errors.append(
                    f"{contract['id']}: NOT_VERIFIED {repo}/{path}: "
                    + str(exc).splitlines()[0]
                )
    return checked, errors


def read_public_main(repo, path):
    url = "https://raw.githubusercontent.com/" + quote(repo, safe="/") + (
        "/main/" + quote(path, safe="/")
    )
    last = None
    for attempt in range(3):
        try:
            with urlopen(url, timeout=12) as response:
                return response.read(1_000_001)
        except (OSError, HTTPError, URLError) as exc:
            last = exc
            if attempt < 2:
                time.sleep(1 + attempt)
    raise OSError("public source fetch failed after retries: " + str(last))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--live", action="store_true", help="verify public main blobs")
    args = parser.parse_args()
    registry = json.loads(REGISTRY.read_text(encoding="utf-8"))
    validate_registry(registry)
    if not args.live:
        print("PASS: shared source registry syntax, completeness and safe targets")
        return 0
    count, errors = check_registry(registry, read_public_main)
    if errors:
        for error in errors:
            print("FAIL:", error, file=sys.stderr)
        print(f"FAIL: shared source drift audit ({len(errors)}/{count} unresolved)")
        return 1
    print(f"PASS: shared source drift audit verified={count} expected=12")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

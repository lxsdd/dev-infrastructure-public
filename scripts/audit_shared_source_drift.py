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
    "bridge-v3-cue-golden": 2,
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



STAGED_ROLLOUT = REGISTRY.parent / "shared-guard-staged-rollout.json"
STAGED_PUBLIC_REPOS = frozenset({
    "lxsdd/dev-infrastructure-public",
    "lxsdd/dj-library-public",
})


def _staged_target(target, *, owner=False):
    if not isinstance(target, dict):
        raise ValueError("invalid immutable staged source target")
    repo, commit, path = (target.get("repo"), target.get("commit"),
                          target.get("path"))
    if not isinstance(repo, str) or repo not in STAGED_PUBLIC_REPOS:
        raise ValueError("unreviewed or private staged source repository")
    if not isinstance(commit, str) or not SHA_RE.fullmatch(commit):
        raise ValueError("mutable or invalid staged source ref")
    if (not isinstance(path, str) or not PATH_RE.fullmatch(path)
            or path.startswith("/") or
            any(p in ("", ".", "..") for p in path.split("/"))):
        raise ValueError("unsafe staged source path")
    sha = target.get("sha1")
    if not isinstance(sha, str) or not SHA_RE.fullmatch(sha):
        raise ValueError("invalid immutable Git blob hash")
    if owner and (repo, path) != (
            "lxsdd/dev-infrastructure-public", "shared/ci/publication_guard.py"):
        raise ValueError("invalid canonical staged guard owner")


def validate_staged_rollout(plan):
    """Schema for public immutable snapshots; intentionally NOT live PR status."""
    if (not isinstance(plan, dict) or plan.get("schema_version") != 1
            or plan.get("contract_id") != "public-guard-staged-immutable-rollout"):
        raise ValueError("unknown immutable staged rollout schema")
    canonical = plan.get("owner")
    _staged_target(canonical, owner=True)
    adopters = plan.get("adoptions")
    if not isinstance(adopters, list) or not adopters:
        raise ValueError("staged contract requires at least one adoption")
    seen = set()
    for entry in adopters:
        _staged_target(entry)
        if entry["repo"] == canonical["repo"]:
            raise ValueError("owner cannot masquerade as a consumer")
        pin_path = entry.get("pin_path")
        if (not isinstance(pin_path, str) or not PATH_RE.fullmatch(pin_path)
                or pin_path.startswith("/") or
                any(part in ("", ".", "..") for part in pin_path.split("/"))):
            raise ValueError("unsafe or missing staged provenance pin path")
        if entry["sha1"] != canonical["sha1"]:
            raise ValueError("staged consumer source Git blob is not canonical")
        key = (entry["repo"], entry["commit"], entry["path"])
        if key in seen or pin_path == entry["path"]:
            raise ValueError("duplicate or self-referential staged consumer")
        seen.add(key)


def check_staged_rollout(plan, fetch):
    """Compare exact-public-commit Git objects; no tokens or write access.

    Pin bytes are verified semantically against the canonical source, not
    treated as a claim that a draft was merged or a native Windows test ran.
    """
    validate_staged_rollout(plan)
    owner = plan["owner"]
    checked, errors = 0, []
    for target in [owner, *plan["adoptions"]]:
        checked += 1
        try:
            data = fetch(target["repo"], target["commit"], target["path"])
            if not isinstance(data, bytes):
                raise TypeError("staged reader did not return bytes")
            if git_blob_sha1(data) != owner["sha1"]:
                errors.append("STAGED_SOURCE_DRIFT: " + target["repo"] +
                              "/" + target["path"])
        except (OSError, ValueError, TypeError, HTTPError, URLError) as exc:
            errors.append("STAGED_NOT_VERIFIED: " + target["repo"] + "/" +
                          target["path"] + ": " + str(exc).splitlines()[0])
    for entry in plan["adoptions"]:
        checked += 1
        try:
            payload = fetch(entry["repo"], entry["commit"], entry["pin_path"])
            if not isinstance(payload, bytes):
                raise TypeError("staged pin reader did not return bytes")
            pin = json.loads(payload.decode("utf-8"))
            if not isinstance(pin, dict) or any([
                    pin.get("source_repo") != owner["repo"],
                    pin.get("source_commit") != owner["commit"],
                    pin.get("source_path") != owner["path"],
                    pin.get("source_git_blob_sha1") != owner["sha1"]]):
                errors.append("STAGED_PIN_MISMATCH: " + entry["repo"])
        except (OSError, ValueError, TypeError, UnicodeError,
                json.JSONDecodeError, HTTPError, URLError) as exc:
            errors.append("STAGED_PIN_NOT_VERIFIED: " + entry["repo"] +
                          ": " + str(exc).splitlines()[0])
    return checked, errors


def read_public_immutable(repo, commit, path):
    """Read source from a reviewed public repository at an immutable SHA."""
    if not isinstance(repo,str) or repo not in STAGED_PUBLIC_REPOS or (
            not isinstance(commit,str) or not SHA_RE.fullmatch(commit)):
        raise ValueError("unreviewed staged source or mutable git ref")
    url = ("https://raw.githubusercontent.com/" + quote(repo, safe="/")
           + "/" + commit + "/" + quote(path, safe="/"))
    last = None
    for attempt in range(3):
        try:
            with urlopen(url, timeout=12) as response:
                # Shared source and tiny pin JSON only, never artifacts.
                return response.read(1_000_001)
        except (OSError, HTTPError, URLError) as exc:
            last = exc
            if attempt < 2:
                time.sleep(1 + attempt)
    raise OSError("immutable public source GET failed: " + str(last))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--live", action="store_true", help="verify public main blobs")
    parser.add_argument("--staged", action="store_true", help="verify immutable public draft source pins")
    args = parser.parse_args()
    if args.live and args.staged:
        parser.error("choose one public source qualification mode")
    if args.staged:
        staged = json.loads(STAGED_ROLLOUT.read_text(encoding="utf-8"))
        count, errors = check_staged_rollout(staged, read_public_immutable)
        if errors:
            for error in errors:
                print("FAIL:", error, file=sys.stderr)
            print(f"FAIL: immutable draft source rollout ({len(errors)}/{count})")
            return 1
        print(f"PASS: STAGED_IMMUTABLE_SOURCE_CHAIN verified={count} (not deployed main)")
        return 0
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
    print(f"PASS: shared source drift audit verified={count} expected=13")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

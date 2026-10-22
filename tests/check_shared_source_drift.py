#!/usr/bin/env python3
"""Adversarial offline tests: public shared-source checks fail closed."""
import copy
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from audit_shared_source_drift import (  # noqa: E402
    REGISTRY, check_registry, git_blob_sha1, validate_registry,
)


def rejects(registry):
    try:
        validate_registry(registry)
    except ValueError:
        return
    raise AssertionError("unsafe or incomplete registry was accepted")


def main():
    original = json.loads(REGISTRY.read_text(encoding="utf-8"))
    validate_registry(original)
    assert git_blob_sha1(b"hello") == hashlib.sha1(
        b"blob 5\0hello"
    ).hexdigest()

    fixture = copy.deepcopy(original)
    payloads = {}
    for entry in fixture["contracts"]:
        source = ("synthetic:" + entry["id"]).encode("ascii")
        entry["sha1"] = git_blob_sha1(source)
        for target in [entry["owner"], *entry["consumers"]]:
            payloads[(target["repo"], target["path"])] = source

    count, errors = check_registry(fixture, lambda repo, path: payloads[(repo, path)])
    assert count == 13 and errors == [], (count, errors)

    count, errors = check_registry(
        fixture, lambda repo, path: payloads[(repo, path)] + b"!"
    )
    assert count == 13 and len(errors) == 13
    assert all("SOURCE_DRIFT" in error for error in errors)

    missing = dict(payloads)
    del missing[next(iter(missing))]

    def missing_fetch(repo, path):
        if (repo, path) not in missing:
            raise OSError("synthetic 404")
        return missing[(repo, path)]
    count, errors = check_registry(fixture, missing_fetch)
    assert count == 13 and len(errors) == 1
    assert "NOT_VERIFIED" in errors[0]

    count, errors = check_registry(fixture, lambda repo, path: "unsafe str")
    assert count == 13 and len(errors) == 13
    assert all("NOT_VERIFIED" in error for error in errors)

    mutated = copy.deepcopy(original)
    mutated["contracts"][0]["consumers"].pop()
    rejects(mutated)
    mutated = copy.deepcopy(original)
    mutated["contracts"].pop()
    rejects(mutated)
    mutated = copy.deepcopy(original)
    mutated["contracts"][0]["sha1"] = "a" * 39
    rejects(mutated)
    mutated = copy.deepcopy(original)
    mutated["contracts"][0]["consumers"][0]["path"] = "../outside.txt"
    rejects(mutated)
    mutated = copy.deepcopy(original)
    mutated["contracts"][0]["consumers"][0]["repo"] = "foreign/unreviewed"
    rejects(mutated)
    mutated = copy.deepcopy(original)
    mutated["contracts"][0]["consumers"][0] = mutated["contracts"][0]["owner"]
    rejects(mutated)
    mutated = copy.deepcopy(original)
    mutated["contracts"][1]["id"] = mutated["contracts"][0]["id"]
    rejects(mutated)

    print("PASS: 13 public targets, real Git blob header and 10 adversarial classes")


if __name__ == "__main__":
    main()

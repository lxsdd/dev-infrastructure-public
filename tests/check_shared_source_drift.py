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
    REGISTRY, STAGED_ROLLOUT, check_registry, check_staged_rollout,
    git_blob_sha1, validate_registry, validate_staged_rollout,
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

    staged = json.loads(STAGED_ROLLOUT.read_text(encoding="utf-8"))
    validate_staged_rollout(staged)
    sample = copy.deepcopy(staged)
    source = b"synthetic-qualified-shared-guard"
    sample["owner"]["sha1"] = git_blob_sha1(source)
    for adopter in sample["adoptions"]:
        adopter["sha1"] = sample["owner"]["sha1"]
    owner = sample["owner"]
    adoption = sample["adoptions"][0]
    pin = {
        "source_repo": owner["repo"],
        "source_commit": owner["commit"],
        "source_path": owner["path"],
        "source_git_blob_sha1": owner["sha1"],
    }
    objects = {
        (owner["repo"], owner["commit"], owner["path"]): source,
        (adoption["repo"], adoption["commit"], adoption["path"]): source,
        (adoption["repo"], adoption["commit"], adoption["pin_path"]):
            json.dumps(pin).encode("utf-8"),
    }

    def staged_fetch(repo, commit, path):
        return objects[(repo, commit, path)]

    count, errors = check_staged_rollout(sample, staged_fetch)
    assert count == 3 and not errors, (count, errors)

    drift = dict(objects)
    drift[(adoption["repo"], adoption["commit"], adoption["path"])] += b"!"
    _, errors = check_staged_rollout(
        sample, lambda repo, commit, path: drift[(repo, commit, path)])
    assert len(errors) == 1 and "STAGED_SOURCE_DRIFT" in errors[0], errors

    drift = dict(objects)
    drift[(owner["repo"], owner["commit"], owner["path"])] += b"!"
    _, errors = check_staged_rollout(
        sample, lambda repo, commit, path: drift[(repo, commit, path)])
    assert len(errors) == 1 and "STAGED_SOURCE_DRIFT" in errors[0], errors

    broken_pin = dict(pin, source_commit="0" * 40)
    drift = dict(objects)
    drift[(adoption["repo"], adoption["commit"], adoption["pin_path"])] = (
        json.dumps(broken_pin).encode("utf-8"))
    _, errors = check_staged_rollout(
        sample, lambda repo, commit, path: drift[(repo, commit, path)])
    assert len(errors) == 1 and "STAGED_PIN_MISMATCH" in errors[0], errors

    drift = dict(objects)
    del drift[(adoption["repo"], adoption["commit"], adoption["pin_path"])]
    _, errors = check_staged_rollout(
        sample, lambda repo, commit, path: drift.get((repo, commit, path)))
    assert len(errors) == 1 and "STAGED_PIN_NOT_VERIFIED" in errors[0], errors

    for field, value in (
        ("repo", "private/source-repository"),
        ("commit", "main"),
        ("path", "../private-source"),
    ):
        mutated = copy.deepcopy(sample)
        mutated["adoptions"][0][field] = value
        try:
            validate_staged_rollout(mutated)
        except ValueError:
            pass
        else:
            raise AssertionError("invalid staged public ref accepted: " + field)
    for mutation in ("duplicate", "missing_pin", "self_pin", "wrong_source",
                     "wrong_owner", "empty_adopters"):
        mutated = copy.deepcopy(sample)
        adopter = mutated["adoptions"][0]
        if mutation == "duplicate":
            mutated["adoptions"].append(copy.deepcopy(adopter))
        elif mutation == "missing_pin":
            adopter.pop("pin_path")
        elif mutation == "self_pin":
            adopter["pin_path"] = adopter["path"]
        elif mutation == "wrong_source":
            adopter["sha1"] = "f" * 40
        elif mutation == "wrong_owner":
            mutated["owner"]["repo"] = "lxsdd/dj-library-public"
        else:
            mutated["adoptions"] = []
        try:
            validate_staged_rollout(mutated)
        except ValueError:
            pass
        else:
            raise AssertionError("unsafe staged rollout accepted: " + mutation)
    print("PASS: immutable staged guard source chain 3 objects and 13 adversarial classes")

    print("PASS: 13 public targets, real Git blob header and 10 adversarial classes")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Portable, secret-free conservation checks for PR-ledger data.

This module intentionally has no GitHub API access, network calls, user-specific
repository names, device access or write operations.
"""
import re

SHA = re.compile(r"[0-9a-f]{40}\Z")
AREAS = {"foobar", "other", "shared"}
STATES = {
    "unreviewed", "adopt", "already_integrated",
    "consolidate", "continue", "defer", "retire",
}
TERMINAL = {"already_integrated", "consolidate", "retire"}


def _fail(message):
    raise ValueError(message)


def _unique(values, what):
    if len(values) != len(set(values)):
        _fail("duplicate " + what)


def validate(projects, snapshot, decisions, initiatives):
    """Check identity/preservation and proof requirements; never infer CI PASS."""
    for name, value in [
        ("projects", projects), ("snapshot", snapshot),
        ("decisions", decisions), ("initiatives", initiatives),
    ]:
        if value.get("schema_version") != 1:
            _fail(name + ": unsupported schema")

    repos = projects.get("repositories", [])
    _unique([r["full_name"] for r in repos], "repository")
    repo_by_name = {r["full_name"]: r for r in repos}
    if len(repos) != snapshot.get("counts", {}).get("repositories"):
        _fail("repository count drift")
    for repo in repos:
        if repo.get("area") not in AREAS:
            _fail("invalid repository area")
        if not repo.get("family"):
            _fail("missing product family")
        if not SHA.fullmatch(repo.get("default_branch_head", "")):
            _fail("invalid repository HEAD SHA")

    prs = snapshot.get("pull_requests", [])
    keys = [(p["repo"], p["number"]) for p in prs]
    _unique(keys, "PR")
    if len(prs) != snapshot.get("counts", {}).get("open_pull_requests"):
        _fail("open PR count drift")
    if sum(p.get("draft") is True for p in prs) != snapshot["counts"].get("draft_pull_requests"):
        _fail("draft PR count drift")
    for p in prs:
        if p["repo"] not in repo_by_name:
            _fail("unknown PR repository")
        if not isinstance(p["number"], int) or p["number"] <= 0:
            _fail("invalid PR number")
        if not SHA.fullmatch(p.get("head_sha", "")):
            _fail("invalid PR HEAD")
        if not SHA.fullmatch(p.get("base_sha", "")):
            _fail("invalid PR base")
        if (p.get("area"), p.get("family")) != (
            repo_by_name[p["repo"]]["area"], repo_by_name[p["repo"]]["family"]
        ):
            _fail("PR product classification drift")
        if p.get("url") != "https://github.com/%s/pull/%s" % (p["repo"], p["number"]):
            _fail("invalid PR identity URL")

    rows = decisions.get("decisions", [])
    dkeys = [(row["repo"], row["number"]) for row in rows]
    _unique(dkeys, "PR decision")
    if set(keys) != set(dkeys):
        _fail("baseline PR missing from decision ledger")
    source = {(p["repo"], p["number"]): p for p in prs}
    for row in rows:
        if row.get("head_sha") != source[(row["repo"], row["number"])]["head_sha"]:
            _fail("decision bound to wrong PR head")
        state = row.get("state")
        if state not in STATES:
            _fail("unsupported decision state")
        if state in TERMINAL:
            if not row.get("review_evidence"):
                _fail("terminal disposition missing reviewed proof")
            if state == "already_integrated":
                if not SHA.fullmatch(row.get("integration_commit") or ""):
                    _fail("integration requires exact commit")
                if row.get("acceptance") != "PASS":
                    _fail("integration requires acceptance evidence")
            if state == "consolidate" and not row.get("replacement"):
                _fail("consolidation missing replacement")
        if state == "unreviewed" and row.get("acceptance") == "PASS":
            _fail("unreviewed PR cannot be accepted")

    items = initiatives.get("initiatives", [])
    _unique([x["id"] for x in items], "initiative")
    known = {"%s#%s" % key for key in keys}
    for item in items:
        if item.get("area") not in AREAS:
            _fail("unknown initiative area")
        if not item.get("acceptance"):
            _fail("initiative needs acceptance gates")
        refs = item.get("references", [])
        if any(ref not in known for ref in refs):
            _fail("initiative references PR outside baseline")
        if item.get("status") in {"qualified", "completed"}:
            evidence = item.get("completion_evidence")
            if not isinstance(evidence, list) or not evidence:
                _fail("qualified initiative requires proof")
            for proof in evidence:
                if not isinstance(proof, dict) or not SHA.fullmatch(proof.get("commit_sha", "")):
                    _fail("initiative proof must include exact commit")
                if proof.get("result") != "PASS" or not proof.get("check_url", "").startswith("https://github.com/"):
                    _fail("initiative proof requires passing CI link")
        if item.get("status") == "completed":
            if any(
                x["state"] == "unreviewed" and "%s#%s" % (x["repo"], x["number"]) in refs
                for x in rows
            ):
                _fail("completed initiative still references unreviewed PR")
    return {"repositories": len(repos), "pull_requests": len(prs), "initiatives": len(items)}

"""Read-only reconciliation of a portfolio branch register against observed PRs.

All private ownership metadata stays with the caller. The public tests use
fictitious entries exclusively. This module does not fetch GitHub, trust
timestamps as locks, write source, archive PRs, launch CI or authorize claims.
"""
from collections import Counter
from collections.abc import Mapping
import re

SHA = re.compile(r"[0-9a-f]{40}\Z")
REPO = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")
MODES = frozenset(("CHAT", "AGENT", "FREI", "BLOCKIERT"))
ISSUES = frozenset((
    "UNVERIFIED_LIVE_PR", "STALE_SOURCE_HEAD", "CLAIM_SOURCE_CONFLICT",
    "CLAIM_LEDGER_CONFLICT", "CLAIM_RECONCILIATION_REQUIRED",
    "MERGED_PR_RECONCILIATION_REQUIRED", "CLOSED_PR_RECONCILIATION_REQUIRED",
    "UNVERIFIED_FREE_HEAD",
))


def _identity(item):
    if not isinstance(item, Mapping):
        return None
    repo, branch, pr = item.get("repository"), item.get("branch"), item.get("pr")
    if (not isinstance(repo, str) or not REPO.fullmatch(repo) or
            not isinstance(branch, str) or not branch or
            type(pr) is not int or pr < 1):
        return None
    return (repo, branch, pr)


def _observed_pr(item):
    identity = _identity(item)
    if (identity is None or not isinstance(item.get("head_sha"), str) or
            not SHA.fullmatch(item["head_sha"]) or
            item.get("state") not in ("open", "closed") or
            type(item.get("merged")) is not bool or
            (item["merged"] and item["state"] != "closed")):
        return None
    return identity


def _owned_entry(item):
    identity = _identity(item)
    if (identity is None or not isinstance(item.get("head_sha"), str) or
            not SHA.fullmatch(item["head_sha"]) or
            item.get("mode") not in MODES or "claim" not in item):
        return None
    claim = item["claim"]
    previous = item.get("last_completed")
    if (previous is not None and
            (not isinstance(previous, Mapping) or
             not isinstance(previous.get("new_head_sha"), str) or
             not SHA.fullmatch(previous["new_head_sha"]))):
        return None
    if claim is not None:
        if (not isinstance(claim, Mapping) or
                claim.get("status") != "ACTIVE" or
                not isinstance(claim.get("worker"), str) or
                not claim["worker"] or
                not isinstance(claim.get("run_id"), str) or
                not claim["run_id"] or
                not isinstance(claim.get("expected_source_head_sha"), str) or
                not SHA.fullmatch(claim["expected_source_head_sha"]) or
                item["mode"] not in ("FREI", "AGENT")):
            return None
    return identity


def _route_status(routes, owners, observations):
    """Compare current-route identities only; historic green runs cannot cure drift."""
    if routes is None:
        return "NOT_EVALUATED"
    if not isinstance(routes, Mapping):
        return "INVALID_ROUTE"
    records = routes.get("routes")
    if not isinstance(records, list):
        return "INVALID_ROUTE"
    rows = [row for row in records
            if isinstance(row, Mapping) and row.get("id") == "public_contract"]
    if len(rows) != 1:
        return "INVALID_ROUTE"
    row = rows[0]
    identity = _identity(row)
    ownership = routes.get("ownership")
    if identity is None or not isinstance(ownership, Mapping):
        return "INVALID_ROUTE"
    if identity not in owners or identity not in observations:
        return "ROUTE_IDENTITY_NOT_VERIFIED"
    owner, observed = owners[identity], observations[identity]
    if (row.get("head_sha") != owner["head_sha"] or
            row.get("head_sha") != observed["head_sha"] or
            ownership.get("public_contract_sha") != row.get("head_sha")):
        return "ROUTE_HEAD_MISMATCH"
    if observed["state"] != "open" or observed["merged"]:
        return "ROUTE_PR_NOT_OPEN"
    pair = row.get("run_ids")
    baseline = row.get("public_baseline_ci")
    if (owner.get("mode") != "CHAT" or owner.get("claim") is not None or
            not isinstance(pair, list) or len(pair) != 2 or
            any(type(n) is not int or n <= 0 for n in pair) or
            pair[0] == pair[1] or
            ownership.get("public_contract_run") != pair[-1] or
            not isinstance(baseline, Mapping) or
            type(baseline.get("run_id")) is not int or
            baseline["run_id"] <= 0 or baseline["run_id"] in pair or
            baseline.get("all_jobs") != "SUCCESS" or
            baseline.get("artifacts_uploaded") is not False or
            row.get("artifacts_uploaded") is not False):
        return "ROUTE_EVIDENCE_INCOMPLETE"
    # This is not verification of genuine GitHub API run/job/artifact evidence.
    return "RECORDED_REFERENCE_COHERENT_NOT_LIVE_CI_VERIFIED"


def reconcile_portfolio(assignments, live_prs, *, routes=None,
                        control_identity=None):
    """Return deterministic classifications; never modify registers or branches.

    An observation must be an independently obtained GitHub PR head/state,
    *not* a copied private ledger row. control_identity may identify the one
    private control PR whose own branch-HEAD cannot self-reference its file.
    It does not exempt other repositories or branches from SHA comparison.
    """
    if not isinstance(assignments, list) or not isinstance(live_prs, list):
        return {"status": "INVALID_INPUT"}
    if control_identity is not None and (
            not isinstance(control_identity, (list, tuple)) or
            len(control_identity) != 3 or
            _identity(dict(zip(("repository", "branch", "pr"),
                               control_identity))) is None):
        return {"status": "INVALID_INPUT"}
    control = tuple(control_identity) if control_identity is not None else None
    owners, live = {}, {}
    owner_branches, live_branches = set(), set()
    owner_prs, live_pr_numbers = set(), set()
    for entries, result, branches, pr_numbers, validate in (
            (assignments, owners, owner_branches, owner_prs, _owned_entry),
            (live_prs, live, live_branches, live_pr_numbers, _observed_pr)):
        for entry in entries:
            key = validate(entry)
            if key is None:
                return {"status": "INVALID_INPUT"}
            if (key in result or key[:2] in branches or
                    (key[0], key[2]) in pr_numbers):
                return {"status": "DUPLICATE_IDENTITY"}
            result[key] = entry
            branches.add(key[:2])
            pr_numbers.add((key[0], key[2]))
    extra = sorted(set(live) - set(owners))
    if extra:
        return {"status": "UNREGISTERED_LIVE_PR", "identities": extra}
    statuses = []
    for key in sorted(owners):
        owner = owners[key]
        observed = live.get(key)
        claim = owner["claim"]
        if observed is None:
            code = "UNVERIFIED_LIVE_PR"
        elif observed["state"] != "open":
            if owner["mode"] == "BLOCKIERT" and claim is None:
                code = "ARCHIVED_CLOSED_OR_MERGED_PR"
            elif observed["merged"]:
                code = "MERGED_PR_RECONCILIATION_REQUIRED"
            else:
                code = "CLOSED_PR_RECONCILIATION_REQUIRED"
        elif claim is not None and claim["expected_source_head_sha"] != owner["head_sha"]:
            code = "CLAIM_LEDGER_CONFLICT"
        elif claim is not None and claim["expected_source_head_sha"] != observed["head_sha"]:
            code = "CLAIM_SOURCE_CONFLICT"
        elif owner["head_sha"] != observed["head_sha"]:
            if key == control and owner["mode"] == "CHAT" and claim is None:
                code = "CONTROL_SELF_REFERENCE_EXPECTED"
            elif claim is not None:
                code = "CLAIM_RECONCILIATION_REQUIRED"
            else:
                code = "STALE_SOURCE_HEAD"
        elif claim is not None:
            code = "ACTIVE_CLAIM_NO_TAKEOVER"
        elif (owner["mode"] == "FREI" and owner.get("last_completed") is not None
              and owner["last_completed"].get("new_head_sha") != owner["head_sha"]):
            code = "UNVERIFIED_FREE_HEAD"
        elif owner["mode"] == "BLOCKIERT":
            code = "BLOCKED_NO_WRITES"
        else:
            code = "CURRENT_OPEN_NO_CLAIM"
        statuses.append({"repository": key[0], "branch": key[1],
                         "pr": key[2], "status": code,
                         "source_head_verified": (observed is not None and
                             observed["head_sha"] == owner["head_sha"])})
    counts = dict(sorted(Counter(row["status"] for row in statuses).items()))
    route = _route_status(routes, owners, live)
    needs_attention = any(row["status"] in ISSUES for row in statuses)
    if route not in ("NOT_EVALUATED",
                     "RECORDED_REFERENCE_COHERENT_NOT_LIVE_CI_VERIFIED"):
        needs_attention = True
    return {"status": "NEEDS_RECONCILIATION" if needs_attention else
            "RECORDED_STATE_CONSISTENT_NOT_AUTHORITY_TO_WRITE",
            "entries": statuses, "counts": counts,
            "public_route": route, "observed": len(live),
            "registered": len(owners)}

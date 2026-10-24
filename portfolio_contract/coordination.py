"""Fail-closed, side-effect-free branch ownership preflight.

The caller MUST fetch GitHub's current branch HEAD and private ledger blob SHA,
then acquire its claim by a compare-and-swap update of that private ledger.
READY_TO_CLAIM never authorizes source writes or proves that a lock was acquired.
No clock-based expiration can silently transfer ownership.
"""
from collections.abc import Mapping
import re

_SHA = re.compile(r"[0-9a-f]{40}\Z")
_MODES = {"CHAT", "AGENT", "FREI", "BLOCKIERT"}
_ACTORS = {"CHAT", "AGENT"}


def ownership_decision(task: Mapping, *, actor: str, assignments,
                       actual_head: str, expected_ledger_sha: str,
                       observed_ledger_sha: str) -> str:
    """Evaluate one prospective branch claim; all data is supplied by the caller."""
    if actor not in _ACTORS:
        return "INVALID_ACTOR"
    if not isinstance(task, Mapping) or not task.get("repository") or not task.get("branch"):
        return "INVALID_TASK"
    if not isinstance(assignments, list):
        return "INVALID_LEDGER"
    if not isinstance(expected_ledger_sha, str) or not _SHA.fullmatch(expected_ledger_sha):
        return "INVALID_LEDGER_SHA"
    if not isinstance(observed_ledger_sha, str) or not _SHA.fullmatch(observed_ledger_sha):
        return "INVALID_LEDGER_SHA"
    if expected_ledger_sha != observed_ledger_sha:
        return "STALE_LEDGER"

    seen = set()
    matching = []
    for entry in assignments:
        if not isinstance(entry, Mapping):
            return "INVALID_ASSIGNMENT"
        key = (entry.get("repository"), entry.get("branch"))
        if not all(isinstance(value, str) and value for value in key):
            return "INVALID_ASSIGNMENT"
        if key in seen:
            return "DUPLICATE_ASSIGNMENT"
        seen.add(key)
        if key == (task["repository"], task["branch"]):
            matching.append(entry)
    if not matching:
        return "MISSING_ASSIGNMENT"
    entry = matching[0]
    if entry.get("mode") not in _MODES or "claim" not in entry:
        return "INVALID_ASSIGNMENT"
    if not isinstance(actual_head, str) or not _SHA.fullmatch(actual_head):
        return "INVALID_HEAD"
    if entry.get("head_sha") != actual_head or task.get("expected_head") != actual_head:
        return "STALE_HEAD"
    if entry["claim"] is not None:
        # Even a supposedly expired claim requires explicit remote reconciliation.
        return "RECONCILE_EXISTING_CLAIM"
    if entry["mode"] == "BLOCKIERT":
        return "BLOCKED"
    if entry["mode"] not in ("FREI", actor):
        return "OTHER_LANE_OWNS_BRANCH"
    return "READY_TO_CLAIM"

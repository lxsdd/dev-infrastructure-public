"""Pure P0-first portfolio work-item selector (no GitHub calls or branch claims).

All timestamps, ownership entries and exact PR states must be independently
observed by the caller. This selector does not run an LLM, acquire a claim,
authorize a merge, or infer a reproducible defect from an initiative label.
"""
from collections.abc import Mapping

from scheduler import dispatch_decision


def select_next(candidates, *, assignments, expected_ledger_sha: str,
                observed_ledger_sha: str, plan_capacity_available: bool,
                actor: str = "AGENT", leases=(), now: int = 0) -> dict:
    """Choose one claim *candidate*: actual source writes still require GitHub CAS.

    Each candidate supplies `task` (scheduler schema), `task_id`, `family`,
    `priority` (P0/P1), `last_success_at` (UTC Unix seconds; 0 means never),
    `reproduction_evidence`, `actual_head` and `actual_pr_state`.
    An unverified PR, missing private ownership or non-reproducible P0 is
    never promoted to READY_TO_CLAIM.
    """
    if not isinstance(candidates, (tuple, list)) or not candidates:
        return {"status": "NO_CANDIDATES", "blocked": []}
    if not isinstance(now, int) or isinstance(now, bool) or now < 0:
        return {"status": "INVALID_CLOCK", "blocked": []}

    seen_ids, seen_branches, family_timestamps = set(), set(), {}
    ready, blocked = [], []
    for candidate in candidates:
        if not isinstance(candidate, Mapping):
            return {"status": "INVALID_CANDIDATES", "blocked": []}
        task = candidate.get("task")
        task_id = candidate.get("task_id")
        family = candidate.get("family")
        priority = candidate.get("priority")
        last = candidate.get("last_success_at")
        if (not isinstance(task, Mapping) or
                not isinstance(task_id, str) or not task_id.strip() or
                not isinstance(family, str) or not family.strip() or
                priority not in ("P0", "P1") or
                not isinstance(last, int) or isinstance(last, bool) or
                last < 0 or last > now or
                not isinstance(task.get("repository"), str) or
                not task.get("repository") or
                not isinstance(task.get("branch"), str) or
                not task.get("branch")):
            return {"status": "INVALID_CANDIDATES", "blocked": []}
        branch_key = (task["repository"], task["branch"])
        if task_id in seen_ids or branch_key in seen_branches:
            return {"status": "AMBIGUOUS_CANDIDATES", "blocked": []}
        seen_ids.add(task_id)
        seen_branches.add(branch_key)
        if family in family_timestamps and family_timestamps[family] != last:
            return {"status": "INCONSISTENT_FAMILY_HISTORY", "blocked": []}
        family_timestamps[family] = last

        evidence = candidate.get("reproduction_evidence")
        if not isinstance(evidence, str) or not evidence.strip():
            blocked.append({"task_id": task_id, "reason": "NOT_REPRODUCED"})
            continue
        result = dispatch_decision(
            task, actual_head=candidate.get("actual_head"),
            actual_pr_state=candidate.get("actual_pr_state"),
            leases=leases, plan_capacity_available=plan_capacity_available,
            now=now, actor=actor, ownership_assignments=assignments,
            expected_ledger_sha=expected_ledger_sha,
            observed_ledger_sha=observed_ledger_sha)
        if result != "READY_TO_CLAIM":
            blocked.append({"task_id": task_id, "reason": result})
            continue
        ready.append((0 if priority == "P0" else 1, last, family,
                      task_id, task["repository"], task["branch"], priority))

    if not ready:
        return {"status": "NO_ELIGIBLE_TASK", "blocked": blocked}
    # Among equal priority, the family with the oldest verified successful
    # progress wins. Stable lexical ties make the selector deterministic.
    rank, last, family, task_id, repository, branch, priority = min(ready)
    return {"status": "READY_TO_CLAIM", "task_id": task_id,
            "repository": repository, "branch": branch, "family": family,
            "priority": priority, "last_success_at": last,
            "blocked": blocked}

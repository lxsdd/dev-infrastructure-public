"""Pure, side-effect-free preflight gates for existing-subscription ChatGPT tasks.

This module neither launches a model nor accesses GitHub. It is safe to run with
synthetic fixtures on public CI; authorization and remote session reconciliation
remain outside this code. It never invokes a paid model API or starts a task.
"""

from collections.abc import Mapping


def dispatch_decision(task: Mapping, *, actual_head: str, leases=(),
                      plan_capacity_available: bool = False, now: int = 0) -> str:
    """Fail-closed preflight; a returned READY is only a permission to *consider* dispatch."""
    required = ("repository", "branch", "expected_head", "state",
                "source_visibility", "runner_kind")
    if any(not task.get(key) for key in required):
        return "INVALID_TASK"
    if task["state"] == "DONE":
        return "ALREADY_DONE"
    if task["state"] != "QUEUED":
        return "NOT_QUEUED"
    if actual_head != task["expected_head"]:
        return "STALE_HEAD"
    if task.get("owner_approval_required") or task.get("risk_flags"):
        return "BLOCKED_OWNER"
    if task.get("requires_paid_api") or task.get("requires_billed_compute"):
        return "PAID_PROVIDER_FORBIDDEN"
    if task["runner_kind"] != "chatgpt_subscription_task":
        return "INVALID_RUNNER"
    if task["source_visibility"] not in {"public", "private"}:
        return "INVALID_TASK"
    if task["source_visibility"] == "private" and task.get("public_ci_repo"):
        return "PRIVACY_BLOCK"
    if task.get("same_failure_count", 0) >= 3:
        return "REPEATED_FAILURE_HOLD"
    if not plan_capacity_available:
        return "PLAN_LIMIT_HOLD"

    for lease in leases:
        if (lease.get("repository") == task["repository"] and
                lease.get("branch") == task["branch"] and
                lease.get("state") in {"RUNNING", "DISPATCHING"}):
            if lease.get("expires_at", 0) <= now:
                # An expired lease is not proof the remote agent has stopped.
                return "RECONCILE_REMOTE"
            return "ALREADY_RUNNING"
    return "READY"


def ci_decision(attestation: Mapping, *, expected_head: str,
                required_jobs: tuple[str, ...]) -> str:
    """Return PASS only for exact-head completed real-step required job success."""
    if not expected_head or not required_jobs:
        return "INVALID_EXPECTATION"
    if attestation.get("head_sha") != expected_head:
        return "STALE_HEAD"
    jobs = attestation.get("jobs")
    if not isinstance(jobs, list):
        return "NOT_RUN"
    found = {}
    for job in jobs:
        name = job.get("name") if isinstance(job, Mapping) else None
        if name in found:
            return "AMBIGUOUS"
        if name:
            found[name] = job
    if any(name not in found for name in required_jobs):
        return "NOT_RUN"
    for name in required_jobs:
        job = found[name]
        if job.get("status") != "completed":
            return "PENDING"
        if not isinstance(job.get("executed_steps"), int) or job["executed_steps"] <= 0:
            return "NOT_RUN"
        if job.get("conclusion") != "success":
            return "FAIL"
    return "PASS"

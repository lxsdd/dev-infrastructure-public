"""Pure, side-effect-free preflight gates for existing-subscription ChatGPT tasks.

This module neither launches a model nor accesses GitHub. It is safe to run with
synthetic fixtures on public CI; authorization and remote session reconciliation
remain outside this code. It never invokes a paid model API or starts a task.
"""

from collections.abc import Mapping

from coordination import ownership_decision


def dispatch_decision(task: Mapping, *, actual_head: str, leases=(),
                      plan_capacity_available: bool = False, now: int = 0,
                      actor: str = "", ownership_assignments=None,
                      expected_ledger_sha: str = "",
                      observed_ledger_sha: str = "",
                      actual_pr_state: str | None = None) -> str:
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
    # This is a preflight only: the caller must atomically claim the private
    # ledger with its GitHub blob SHA and re-read it before touching source.
    return ownership_decision(
        task, actor=actor, assignments=ownership_assignments,
        actual_head=actual_head, expected_ledger_sha=expected_ledger_sha,
        observed_ledger_sha=observed_ledger_sha,
        actual_pr_state=actual_pr_state)


def ci_decision(attestation: Mapping, *, expected_head: str,
                required_jobs: tuple[str, ...],
                require_no_artifacts: bool = False) -> str:
    """Evaluate an exact-source, real-step CI witness without making API calls.

    Callers that attest a source-only workflow MUST supply the actual workflow-run
    artifact inventory and set require_no_artifacts=True. A missing inventory is
    not proof of zero published binaries; it cannot be silently interpreted as [].
    A PR-only run lookup returning [] for a push event likewise means NOT_RUN,
    not a tested failure. The caller must discover the push run independently.
    """
    if (not isinstance(expected_head, str) or not expected_head or
            not isinstance(required_jobs, (tuple, list)) or not required_jobs or
            any(not isinstance(name, str) or not name for name in required_jobs) or
            len(set(required_jobs)) != len(required_jobs)):
        return "INVALID_EXPECTATION"
    if not isinstance(attestation, Mapping):
        return "INVALID_ATTESTATION"
    if attestation.get("head_sha") != expected_head:
        return "STALE_HEAD"
    jobs = attestation.get("jobs")
    if not isinstance(jobs, list):
        return "NOT_RUN"
    found = {}
    for job in jobs:
        # API and cached CI evidence are external input. Invalid job entries
        # must never crash this fail-closed attestation gate.
        if not isinstance(job, Mapping):
            return "INVALID_ATTESTATION"
        name = job.get("name")
        if not isinstance(name, str) or not name:
            return "INVALID_ATTESTATION"
        if name in found:
            return "AMBIGUOUS"
        found[name] = job
    if any(name not in found for name in required_jobs):
        return "NOT_RUN"
    for name in required_jobs:
        job = found[name]
        if job.get("status") != "completed":
            return "PENDING"
        steps = job.get("executed_steps")
        if not isinstance(steps, int) or isinstance(steps, bool) or steps <= 0:
            return "NOT_RUN"
        if job.get("conclusion") != "success":
            return "FAIL"
    if require_no_artifacts:
        artifacts = attestation.get("artifacts")
        if not isinstance(artifacts, list):
            return "ARTIFACTS_NOT_VERIFIED"
        if artifacts:
            return "ARTIFACTS_PRESENT"
    return "PASS"

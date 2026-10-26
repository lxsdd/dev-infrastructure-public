"""Deterministic exact-commit multi-workflow CI qualification; no network or writes.

Upstream callers must fetch workflow-run metadata, exact jobs/steps, and the
independent artifact inventory from GitHub. This pure function never initiates
builds or accepts a passed boolean as a substitute for actual job evidence.
"""
from collections.abc import Mapping
import re

from scheduler import ci_decision

SHA = re.compile(r"[0-9a-f]{40}\Z")
REPO = re.compile(r"[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+\Z")
EVENTS = frozenset(("push", "pull_request", "workflow_dispatch"))


def qualification_bundle_decision(witnesses, *, expected_head,
                                  expected_repository, required_runs):
    """Require distinct, completed, green runs for every declared workflow role.

    required_runs:
      [{"role": "portfolio_push", "event": "push",
        "workflow": "Public portfolio preservation contract",
        "required_jobs": ["contract"],
        "required_steps": {"contract": ["Run actual regression suite"]}}, ...]
    witnesses:
      [{"role": "portfolio_push", "run_id": 100, "event": "push",
        "repository": "example/public-ci",
        "workflow": "...", "head_sha": "a"*40,
        "status": "completed", "conclusion": "success",
        "jobs": [{"name": "contract", "status": "completed",
                  "conclusion": "success", "executed_steps": 5,
                  "steps": [{"name": "Run actual regression suite",
                             "status": "completed", "conclusion": "success"}]}],
        "artifacts": []}, ...]

    A PASS proves only internally consistent caller-supplied evidence. It does
    not authenticate a forged GitHub response, verify binary compatibility,
    clear licenses, or permit a merge, release, billing or source publication.
    """
    if (not isinstance(expected_head, str) or not SHA.fullmatch(expected_head)
            or not isinstance(expected_repository, str)
            or not REPO.fullmatch(expected_repository)):
        return "INVALID_EXPECTATION"
    if not isinstance(required_runs, (list, tuple)) or not required_runs:
        return "INVALID_EXPECTATION"
    needed = {}
    identities = set()
    for spec in required_runs:
        if not isinstance(spec, Mapping):
            return "INVALID_EXPECTATION"
        role, event, workflow = (spec.get("role"), spec.get("event"),
                                 spec.get("workflow"))
        names = spec.get("required_jobs")
        if (not isinstance(role, str) or not role or
                not isinstance(workflow, str) or not workflow or
                not isinstance(event, str) or event not in EVENTS or
                not isinstance(names, (tuple, list)) or not names or
                any(not isinstance(name, str) or not name for name in names) or
                len(names) != len(set(names))):
            return "INVALID_EXPECTATION"
        required_steps = spec.get("required_steps", {})
        if (not isinstance(required_steps, Mapping) or
                any(not isinstance(job_name, str) or job_name not in names or
                    not isinstance(step_names, (list, tuple)) or not step_names or
                    any(not isinstance(v, str) or not v for v in step_names) or
                    len(step_names) != len(set(step_names))
                    for job_name, step_names in required_steps.items())):
            return "INVALID_EXPECTATION"
        if role in needed or (event, workflow) in identities:
            return "INVALID_EXPECTATION"
        needed[role] = spec
        identities.add((event, workflow))
    if not isinstance(witnesses, list):
        return "INVALID_ATTESTATION"
    if not witnesses:
        return "NOT_RUN"
    found = {}
    ids = set()
    for witness in witnesses:
        if not isinstance(witness, Mapping):
            return "INVALID_ATTESTATION"
        role, run_id = witness.get("role"), witness.get("run_id")
        if (not isinstance(role, str) or not role or
                type(run_id) is not int or run_id <= 0):
            return "INVALID_ATTESTATION"
        if role in found or run_id in ids:
            return "AMBIGUOUS"
        found[role] = witness
        ids.add(run_id)
    if any(role not in needed for role in found):
        return "UNREVIEWED_RUN"
    if any(role not in found for role in needed):
        return "NOT_RUN"
    for role, spec in needed.items():
        witness = found[role]
        if (witness.get("event") != spec["event"] or
                witness.get("workflow") != spec["workflow"]):
            return "WRONG_WORKFLOW"
        if witness.get("repository") != expected_repository:
            return "WRONG_REPOSITORY"
        if witness.get("head_sha") != expected_head:
            return "STALE_HEAD"
        if witness.get("status") != "completed":
            return "PENDING"
        if witness.get("conclusion") != "success":
            return "FAIL"
        status = ci_decision(
            witness, expected_head=expected_head,
            required_jobs=spec["required_jobs"], require_no_artifacts=True)
        if status != "PASS":
            return status
        # A successful job may still have skipped the actual test step.
        # Job setup/checkout/cleanup steps are not sufficient qualification.
        selected = {job["name"]: job for job in witness["jobs"]}
        for job_name, needed_steps in spec.get("required_steps", {}).items():
            steps = selected[job_name].get("steps")
            if not isinstance(steps, list):
                return "STEPS_NOT_VERIFIED"
            step_map = {}
            for step in steps:
                if (not isinstance(step, Mapping) or
                        not isinstance(step.get("name"), str) or
                        not step["name"]):
                    return "INVALID_ATTESTATION"
                if step["name"] in step_map:
                    return "AMBIGUOUS"
                step_map[step["name"]] = step
            for name in needed_steps:
                if name not in step_map:
                    return "STEPS_NOT_VERIFIED"
                step = step_map[name]
                if step.get("status") != "completed":
                    return "PENDING"
                if step.get("conclusion") == "skipped":
                    return "STEPS_NOT_VERIFIED"
                if step.get("conclusion") != "success":
                    return "FAIL"
    return "PASS"

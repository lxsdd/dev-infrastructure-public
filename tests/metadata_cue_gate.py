"""Pure validation of metadata/CUE change plans; never opens or writes media."""
from __future__ import annotations

import re

SCOPES = frozenset({"physical_tags", "embedded_cue", "external_cue"})
SOURCES = frozenset({"user_review", "licensed_public"})
HEX64 = re.compile(r"^[0-9a-f]{64}$")
ID = re.compile(r"^synthetic:[A-Za-z0-9_.-]+$")


class PlanRejected(ValueError):
    """The proposed operation does not meet the release safety contract."""


def validate_plan(plan: dict) -> dict:
    """Validate a single explicit edit plan and return a non-writing decision.

    A change to embedded/external CUE never authorizes physical-tag writes.
    An unchanged digest must not trigger a write; changed digests require
    explicit approval and traceable provenance. No filesystem operations.
    """
    if not isinstance(plan, dict):
        raise PlanRejected("Plan must be an object")
    required = {
        "artifact_id", "scope", "before_sha256", "after_sha256",
        "intended_write", "approved", "provenance",
    }
    if set(plan) != required:
        raise PlanRejected("Plan has missing or unexpected fields")
    if not isinstance(plan["artifact_id"], str) or not ID.fullmatch(plan["artifact_id"]):
        raise PlanRejected("Only opaque synthetic artifact IDs are accepted")
    if plan["scope"] not in SCOPES:
        raise PlanRejected("Unknown or mixed metadata/CUE scope")
    if any(not isinstance(plan[key], str) or not HEX64.fullmatch(plan[key])
           for key in ("before_sha256", "after_sha256")):
        raise PlanRejected("Both SHA-256 digests must be lowercase 64-digit hex")
    if type(plan["intended_write"]) is not bool or type(plan["approved"]) is not bool:
        raise PlanRejected("Write intent and approval must be explicit booleans")
    provenance = plan["provenance"]
    if not isinstance(provenance, dict) or set(provenance) != {"source", "reference", "license_cleared"}:
        raise PlanRejected("Provenance must be complete")
    if provenance["source"] not in SOURCES or not isinstance(provenance["reference"], str) or not provenance["reference"].strip():
        raise PlanRejected("Unknown or untraceable source")
    if provenance["license_cleared"] is not True:
        raise PlanRejected("Provenance lacks explicit license clearance")
    changed = plan["before_sha256"] != plan["after_sha256"]
    if not changed and plan["intended_write"]:
        raise PlanRejected("No-op must not perform a write")
    if changed and (not plan["intended_write"] or not plan["approved"]):
        raise PlanRejected("Changes require explicit write intent and approval")
    return {
        "artifact_id": plan["artifact_id"],
        "scope": plan["scope"],
        "decision": "REVIEWED_CHANGE" if changed else "NO_OP",
        "would_write": changed,
    }

#!/usr/bin/env python3
"""Public, secret-free evidence verifier for central Discogs OAuth1 live QA.

Checks the latest *completed* central main-branch OAuth1 live run and
its required job steps using GitHub's public REST API. This is NOT a
native Discogger GUI/tagging test. No GitHub token, Discogs secret, local
media, PR code, or third-party package is read.
"""
import argparse
import datetime as dt
import json
import re
import sys
from urllib.request import Request, urlopen

OWNER_REPO = "lxsdd/dev-infrastructure-public"
WORKFLOW_ID = 393372974
WORKFLOW_PATH = ".github/workflows/discogs-oauth-live-qa.yml"
WORKFLOW_NAME = "Discogs central OAuth live QA"
JOB_NAME = "Protected OAuth1 identity and five public release regressions"
REQUIRED_STEPS = frozenset({
    "Validate OAuth signature logic without secrets",
    "Official Discogs OAuth1 read-only live acceptance",
})
API_ROOT = "https://api.github.com/repos/" + OWNER_REPO
UTC = dt.timezone.utc


def timestamp(value):
    if not isinstance(value, str) or not value.endswith("Z"):
        raise ValueError("INVALID_PUBLIC_DATE")
    obj = dt.datetime.fromisoformat(value[:-1] + "+00:00")
    return obj.astimezone(UTC)


def validate_runs(payload, now, max_age_hours):
    if not isinstance(payload, dict) or not isinstance(payload.get("workflow_runs"), list):
        raise ValueError("UNEXPECTED_PUBLIC_RUNS_FORMAT")
    eligible = []
    for run in payload["workflow_runs"]:
        if not isinstance(run, dict):
            continue
        repo = run.get("repository")
        if not isinstance(repo, dict) or repo.get("full_name") != OWNER_REPO:
            continue
        if (run.get("workflow_id") != WORKFLOW_ID or
                run.get("head_branch") != "main" or
                run.get("event") not in ("workflow_dispatch", "schedule") or
                run.get("path", "").split("@", 1)[0] != WORKFLOW_PATH or
                not re.fullmatch(r"[a-f0-9]{40}", run.get("head_sha", ""))):
            continue
        try:
            created = timestamp(run["created_at"])
        except (KeyError, ValueError, TypeError):
            continue
        if run.get("status") != "completed":
            continue
        eligible.append((created, run))
    if not eligible:
        raise ValueError("NO_COMPLETED_CENTRAL_OAUTH_RUN")
    created, run = max(eligible, key=lambda item: (item[0], item[1].get("id", 0)))
    if run.get("conclusion") != "success":
        raise ValueError("LATEST_CENTRAL_OAUTH_RUN_FAILED")
    hours = (now - created).total_seconds() / 3600
    if hours < -0.2 or hours > max_age_hours:
        raise ValueError("STALE_OR_INVALID_CENTRAL_OAUTH_RUN")
    identifier = run.get("id")
    if not isinstance(identifier, int) or identifier < 1:
        raise ValueError("INVALID_PUBLIC_RUN_ID")
    return identifier, hours


def validate_jobs(payload):
    if not isinstance(payload, dict) or not isinstance(payload.get("jobs"), list):
        raise ValueError("UNEXPECTED_PUBLIC_JOBS_FORMAT")
    matched = [
        job for job in payload["jobs"]
        if isinstance(job, dict) and job.get("name") == JOB_NAME and
        job.get("status") == "completed" and job.get("conclusion") == "success"
    ]
    if len(matched) != 1:
        raise ValueError("OAUTH_LIVE_JOB_MISSING_OR_FAILED")
    steps = matched[0].get("steps")
    if not isinstance(steps, list):
        raise ValueError("OAUTH_LIVE_STEPS_MISSING")
    passed = {
        step.get("name") for step in steps
        if isinstance(step, dict) and step.get("status") == "completed" and
        step.get("conclusion") == "success"
    }
    if not REQUIRED_STEPS <= passed:
        raise ValueError("OAUTH_REQUIRED_STEPS_NOT_SUCCESSFUL")


def fetch_public(path):
    if not path.startswith("/") or re.search(r"[?#]|//", path):
        raise ValueError("UNAPPROVED_PUBLIC_API_ROUTE")
    address = API_ROOT + path
    req = Request(address, headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "lxsdd-discogs-public-evidence/1.0",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    with urlopen(req, timeout=16) as response:
        if response.status != 200:
            raise ValueError("PUBLIC_GITHUB_API_UNAVAILABLE")
        raw = response.read(2_000_001)
        if len(raw) > 2_000_000:
            raise ValueError("PUBLIC_GITHUB_API_TOO_LARGE")
        return json.loads(raw)


def live(max_age_hours):
    runs = fetch_public(f"/actions/workflows/{WORKFLOW_ID}/runs")
    run_id, age = validate_runs(runs, dt.datetime.now(UTC), max_age_hours)
    jobs = fetch_public(f"/actions/runs/{run_id}/jobs")
    validate_jobs(jobs)
    print(f"CENTRAL_DISCOGS_OAUTH_EVIDENCE=PASS run={run_id} age_hours={age:.1f}")
    print("EVIDENCE_SCOPE=official Discogs OAuth1 API identity and 5 known releases")
    print("NATIVE_DISCOGGER_GUI_TAGGING=NOT_TESTED")


def selftest():
    now = dt.datetime(2026, 10, 23, 10, 0, tzinfo=UTC)
    good = {
        "id": 39920726555, "workflow_id": WORKFLOW_ID, "head_branch": "main",
        "event": "workflow_dispatch", "path": WORKFLOW_PATH,
        "head_sha": "c1f8a20cb9bb60690f962b485ae9cf4acda416bf",
        "repository": {"full_name": OWNER_REPO},
        "status": "completed", "conclusion": "success",
        "created_at": "2026-10-23T07:52:42Z",
    }
    result = validate_runs({"workflow_runs": [good]}, now, 72)
    assert result[0] == 39920726555 and 2 < result[1] < 3
    good_jobs = {"jobs": [{
        "name": JOB_NAME, "status": "completed", "conclusion": "success",
        "steps": [{"name": n, "status": "completed", "conclusion": "success"}
                  for n in REQUIRED_STEPS],
    }]}
    validate_jobs(good_jobs)
    cases = [
        ({"workflow_runs": [dict(good, conclusion="failure")]},
         "LATEST_CENTRAL_OAUTH_RUN_FAILED"),
        ({"workflow_runs": [dict(good, created_at="2026-10-10T00:00:00Z")]},
         "STALE_OR_INVALID_CENTRAL_OAUTH_RUN"),
        ({"workflow_runs": [dict(good, event="pull_request")]},
         "NO_COMPLETED_CENTRAL_OAUTH_RUN"),
        ({"workflow_runs": [dict(good, repository={"full_name": "somebody/else"})]},
         "NO_COMPLETED_CENTRAL_OAUTH_RUN"),
        ({"workflow_runs": [dict(good, workflow_id=55)]},
         "NO_COMPLETED_CENTRAL_OAUTH_RUN"),
        ({"workflow_runs": [dict(good, head_branch="feature/pull-request")]},
         "NO_COMPLETED_CENTRAL_OAUTH_RUN"),
        ({"workflow_runs": [dict(good, path=".github/workflows/unsafe.yml")]},
         "NO_COMPLETED_CENTRAL_OAUTH_RUN"),
        ({"workflow_runs": [dict(good, head_sha="untrusted")]},
         "NO_COMPLETED_CENTRAL_OAUTH_RUN"),
        ({"workflow_runs": [dict(good, created_at="2026-10-23T07:52:42Z"),
                            dict(good, id=39920726556, conclusion="failure",
                                 created_at="2026-10-23T08:52:42Z")]},
         "LATEST_CENTRAL_OAUTH_RUN_FAILED"),
    ]
    for candidate, expected in cases:
        try:
            validate_runs(candidate, now, 72)
            raise AssertionError("Bad public run accepted")
        except ValueError as exc:
            assert str(exc) == expected, (str(exc), expected)
    try:
        validate_jobs({"jobs": [{
            "name": JOB_NAME, "status": "completed", "conclusion": "success",
            "steps": [{"name": n, "status": "completed", "conclusion": "success"}
                      for n in REQUIRED_STEPS if not n.startswith("Official")],
        }]})
        raise AssertionError("Missing official API step accepted")
    except ValueError as exc:
        assert str(exc) == "OAUTH_REQUIRED_STEPS_NOT_SUCCESSFUL"
    print("CENTRAL_DISCOGS_OAUTH_EVIDENCE_SELFTEST=PASS")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--max-age-hours", type=int, default=72)
    args = parser.parse_args()
    if not 6 <= args.max_age_hours <= 168:
        raise SystemExit("Evidence validity must be between 6 and 168 hours")
    try:
        selftest() if args.selftest else live(args.max_age_hours)
    except Exception as exc:
        if isinstance(exc, ValueError) and re.fullmatch(r"[A-Z0-9_]+", str(exc)):
            print("CENTRAL_DISCOGS_OAUTH_EVIDENCE=REVIEW_REQUIRED " + str(exc), file=sys.stderr)
        else:
            print("CENTRAL_DISCOGS_OAUTH_EVIDENCE=REVIEW_REQUIRED PUBLIC_API_CHECK_FAILED", file=sys.stderr)
        raise SystemExit(1)

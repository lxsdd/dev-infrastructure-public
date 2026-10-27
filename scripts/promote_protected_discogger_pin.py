#!/usr/bin/env python3
"""Prepare a reviewed Discogger native OAuth QA SHA change; never executes QA or uses OAuth.
Requires independently successful EXACT product push CI. Writes only the two known workflow
text files with --apply; protected main-only merge remains a separate owner approval.
"""
import argparse
import json
import os
import re
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, Request, build_opener

REPO = "lxsdd/foo_discogger"
PRODUCT_BRANCH = "fix/discogger-optional-fallback-failure-20261026"
REQUIRED = {"portable-core", "windows-baseline", "windows-native-unit (x86)",
            "windows-native-unit (x64)", "official-sdk-probe"}
WORKFLOWS = [
    (".github/workflows/discogs-authenticated-native-gui.yml", 2),
    (".github/workflows/discogs-authenticated-native-gui-policy.yml", 3),
]
SHA = re.compile(r"^[0-9a-f]{40}$")
REF = re.compile(r"(?m)^          ref: ([0-9a-f]{40})$")
SOURCE = re.compile(r"(?m)if\(\(& git (?:-C discogger )?rev-parse HEAD\)\.Trim\(\) -cne '([0-9a-f]{40})'\)")


class PromotionError(RuntimeError):
    pass


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise PromotionError("API redirect prohibited")


def _read_json(path):
    url = "https://api.github.com/repos/" + REPO + "/" + path
    headers = {"Accept": "application/vnd.github+json",
               "X-GitHub-Api-Version": "2022-11-28",
               "User-Agent": "protected-discogger-pin-v1"}
    token = os.getenv("GITHUB_TOKEN", "")
    if token:
        headers["Authorization"] = "Bearer " + token
    try:
        with build_opener(NoRedirect()).open(Request(url, headers=headers), timeout=20) as result:
            raw = result.read(2_000_001)
        if len(raw) > 2_000_000:
            raise PromotionError("API response larger than expected")
        return json.loads(raw)
    except (HTTPError, URLError, ValueError) as exc:
        raise PromotionError("public source CI evidence unavailable") from None


def verify_source_qualification(sha, run_id, get_json=_read_json):
    if not SHA.fullmatch(sha) or type(run_id) is not int or run_id <= 0:
        raise PromotionError("exact source SHA and positive run ID required")
    run = get_json("actions/runs/" + str(run_id))
    if not isinstance(run, dict) or any((
        run.get("head_sha") != sha, run.get("event") != "push",
        run.get("status") != "completed", run.get("conclusion") != "success",
        run.get("head_branch") != PRODUCT_BRANCH,
        (run.get("head_repository") or {}).get("full_name") != REPO,
        run.get("name") != "Discogger modernization validation",
    )):
        raise PromotionError("source CI identity, event, branch or qualification mismatch")
    jobs = get_json("actions/runs/" + str(run_id) + "/jobs?per_page=100")
    rows = jobs.get("jobs") if isinstance(jobs, dict) else None
    if not isinstance(rows, list) or type(jobs.get("total_count")) is not int or len(rows) != jobs["total_count"]:
        raise PromotionError("incomplete or paginated CI jobs")
    results = {}
    for job in rows:
        name = job.get("name") if isinstance(job, dict) else None
        if not isinstance(name, str) or name in results:
            raise PromotionError("ambiguous CI job")
        results[name] = job
        if name != "authorized-discogs-live" and job.get("conclusion") not in ("success",):
            raise PromotionError("unexpected failed or skipped CI job")
    if not REQUIRED.issubset(results):
        raise PromotionError("required product CI jobs absent")
    for name in REQUIRED:
        job = results[name]
        steps = job.get("steps")
        if job.get("status") != "completed" or job.get("conclusion") != "success" or not isinstance(steps, list):
            raise PromotionError("required source/native host qualification incomplete")
        if not any(s.get("conclusion") == "success" and s.get("name") not in
                   ("Set up job", "Complete job") for s in steps if isinstance(s, dict)):
            raise PromotionError("no executed job step evidence")
        if any(s.get("conclusion") not in ("success", "skipped") for s in steps if isinstance(s, dict)):
            raise PromotionError("failed or unverified required job step")
    if "authorized-discogs-live" in results and results["authorized-discogs-live"].get("conclusion") != "skipped":
        raise PromotionError("product repository unexpectedly executed authorized secret gate")
    art = get_json("actions/runs/" + str(run_id) + "/artifacts?per_page=100")
    if not isinstance(art, dict) or art.get("total_count") != 0 or art.get("artifacts") != []:
        raise PromotionError("source CI uploaded artifacts or artifact inventory missing")
    return {"product_sha": sha, "qualified_run_id": run_id,
            "qualified_jobs": sorted(REQUIRED), "artifacts": 0,
            "protected_native_oauth": "STILL_NOT_TESTED_UNTIL_APPROVED_MAIN"}


def prepare(root, sha):
    if not SHA.fullmatch(sha):
        raise PromotionError("invalid source SHA")
    paths = [(root / name, count) for name, count in WORKFLOWS]
    strings = [(path.read_text(encoding="utf-8"), count) for path, count in paths]
    # All references must agree before or after update. No grep-and-replace of
    # unrelated source, vendor, companion or action SHA pins.
    src, policy = strings[0][0], strings[1][0]
    m = re.search(r"(?m)^          repository: lxsdd/foo_discogger\n          ref: ([0-9a-f]{40})$", src)
    if not m:
        raise PromotionError("native product checkout pin not found")
    old = m.group(1)
    if (src.count(old) != 2 or policy.count(old) != 3 or
            src.count("environment: discogs-live-qa") != 1 or
            "github.ref == 'refs/heads/main'" not in src or
            "  pull_request:" in src.split("jobs:", 1)[0] or
            "pull_request_target:" in src or
            "actions/upload-artifact" in src or
            "secrets.DISCOGS_OAUTH_CONSUMER_KEY" not in src or
            "src.count(" not in policy and ' in src' not in policy):
        raise PromotionError("baseline protected workflow policy mismatch")
    for key in ("CONSUMER_KEY", "CONSUMER_SECRET", "ACCESS_TOKEN", "TOKEN_SECRET"):
        if src.count("secrets.DISCOGS_OAUTH_" + key) != 2:
            raise PromotionError("protected credential scope mismatch")
    new = [content.replace(old, sha) for content, _ in strings]
    for (content, count), updated in zip(strings, new):
        if updated.count(sha) != count:
            raise PromotionError("workflow SHA reference count drift")
    return old, tuple((path, updated) for (path, _), updated in zip(paths, new))


def read_target(root):
    path = root / "contracts/discogger-reviewed-native-source.json"
    target = json.loads(path.read_text(encoding="utf-8"))
    if (not isinstance(target, dict) or target.get("schema_version") != 1 or
        target.get("source_repository") != REPO or target.get("source_pr") != 23 or
        target.get("source_branch") != PRODUCT_BRANCH or
        not SHA.fullmatch(target.get("source_sha", "")) or
        type(target.get("qualified_push_run_id")) is not int or
        target.get("qualified_push_run_id") <= 0 or
        target.get("required_releases") !=
        ["38012673", "37332711", "36397609", "36819730", "35534398"]):
        raise PromotionError("reviewed immutable source target invalid")
    return path, target


def main(argv=None):
    p = argparse.ArgumentParser(description="Prepare secure exact qualified native OAuth QA promotion")
    p.add_argument("--qualified-sha", help="new source SHA for a separate protected source promotion PR")
    p.add_argument("--qualified-run", type=int, help="real exact SHA source CI push run")
    p.add_argument("--root", default=".")
    p.add_argument("--apply", action="store_true", help="change only two pinned workflow source files")
    args = p.parse_args(argv)
    try:
        root = Path(args.root)
        target_path, target = read_target(root)
        explicit = args.qualified_sha is not None or args.qualified_run is not None
        if explicit and (not args.qualified_sha or args.qualified_run is None):
            raise PromotionError("source SHA and exact successful push run must be supplied together")
        if args.apply and not explicit:
            raise PromotionError("refuse implicit write; explicit reviewed new SHA and CI required")
        new_sha = args.qualified_sha if explicit else target["source_sha"]
        run_id = args.qualified_run if explicit else target["qualified_push_run_id"]
        evidence = verify_source_qualification(new_sha, run_id)
        old, changes = prepare(root, new_sha)
        if old != target["source_sha"]:
            raise PromotionError("source workflow pins do not match reviewed immutable manifest")
        if args.apply:
            for path, data in changes:
                path.write_text(data, encoding="utf-8")
            target["source_sha"] = new_sha
            target["qualified_push_run_id"] = run_id
            target["protected_native_oauth"] = "PENDING_PROTECTED_MAIN_ONLY"
            target_path.write_text(json.dumps(target, indent=2) + "\n", encoding="utf-8")
        print(json.dumps({"old_sha": old, "new_sha": new_sha,
                          "reviewed_push_run_id": run_id,
                          "updated_files": [str(path) for path, _ in changes] +
                                           ([str(target_path)] if args.apply else []),
                          "applied": args.apply, "evidence": evidence}, sort_keys=True))
        return 0
    except (PromotionError, OSError) as exc:
        print("DENIED: " + str(exc))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

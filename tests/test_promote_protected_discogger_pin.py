"""Secret-free positive/negative qualification and protected pin promotion regression."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
module_spec = importlib.util.spec_from_file_location("pin", ROOT / "scripts/promote_protected_discogger_pin.py")
pin = importlib.util.module_from_spec(module_spec)
module_spec.loader.exec_module(pin)
SHA = "9d66c668589482ca061c934685b23dedfb347fb0"
OLD = "c5a5ec321c359186c32cf1a4f2509ceaf033b7d4"
REQUIRED = [
    "portable-core", "windows-baseline", "windows-native-unit (x86)",
    "windows-native-unit (x64)", "official-sdk-probe",
]


def snapshot():
    run = {
        "head_sha": SHA, "event": "push", "status": "completed",
        "conclusion": "success", "head_branch": pin.PRODUCT_BRANCH,
        "head_repository": {"full_name": pin.REPO},
        "name": "Discogger modernization validation",
    }
    jobs = {"total_count": 6, "jobs": [
        {"name": name, "status": "completed", "conclusion": "success",
         "steps": [{"name": "Perform host/native source test", "conclusion": "success"}]}
        for name in REQUIRED
    ] + [{"name": "authorized-discogs-live", "status": "completed",
          "conclusion": "skipped", "steps": []}]}
    art = {"total_count": 0, "artifacts": []}
    return [run, jobs, art]


def checked(data):
    def fetch(path):
        if path.endswith("/jobs?per_page=100"):
            return data[1]
        if path.endswith("/artifacts?per_page=100"):
            return data[2]
        return data[0]
    return pin.verify_source_qualification(SHA, 40535730661, fetch)


class CIProof(unittest.TestCase):
    def test_push_success_not_pr_only(self):
        self.assertEqual(checked(snapshot())["product_sha"], SHA)

    def test_wrong_source_refused(self):
        d = snapshot(); d[0]["head_sha"] = "b" * 40
        with self.assertRaises(pin.PromotionError): checked(d)

    def test_invalid_repo_denied(self):
        d = snapshot(); d[0]["head_repository"]["full_name"] = "attacker/fork"
        with self.assertRaises(pin.PromotionError): checked(d)

    def test_wrong_branch_denied(self):
        d = snapshot(); d[0]["head_branch"] = "refs/heads/untrusted"
        with self.assertRaises(pin.PromotionError): checked(d)

    def test_pr_event_denied(self):
        d = snapshot(); d[0]["event"] = "pull_request"
        with self.assertRaises(pin.PromotionError): checked(d)

    def test_run_not_completed_denied(self):
        d = snapshot(); d[0]["status"] = "in_progress"
        with self.assertRaises(pin.PromotionError): checked(d)

    def test_run_failure_denied(self):
        d = snapshot(); d[0]["conclusion"] = "failure"
        with self.assertRaises(pin.PromotionError): checked(d)

    def test_missing_native_x86_denied(self):
        d = snapshot(); d[1]["jobs"] = [x for x in d[1]["jobs"] if x["name"] != "windows-native-unit (x86)"]
        d[1]["total_count"] -= 1
        with self.assertRaises(pin.PromotionError): checked(d)

    def test_skipped_native_x64_denied(self):
        d = snapshot(); d[1]["jobs"][3]["conclusion"] = "skipped"
        with self.assertRaises(pin.PromotionError): checked(d)

    def test_failed_native_step_denied(self):
        d = snapshot(); d[1]["jobs"][3]["steps"][0]["conclusion"] = "failure"
        with self.assertRaises(pin.PromotionError): checked(d)

    def test_no_native_execution_denied(self):
        d = snapshot(); d[1]["jobs"][3]["steps"] = []
        with self.assertRaises(pin.PromotionError): checked(d)

    def test_job_pagination_denied(self):
        d = snapshot(); d[1]["total_count"] = 200
        with self.assertRaises(pin.PromotionError): checked(d)

    def test_duplicate_job_denied(self):
        d = snapshot(); d[1]["jobs"][0]["name"] = "windows-native-unit (x64)"
        with self.assertRaises(pin.PromotionError): checked(d)

    def test_artifact_upload_denied(self):
        d = snapshot(); d[2]["total_count"] = 1
        with self.assertRaises(pin.PromotionError): checked(d)

    def test_unauthorized_product_live_denied(self):
        d = snapshot(); d[1]["jobs"][-1]["conclusion"] = "success"
        with self.assertRaises(pin.PromotionError): checked(d)

    def test_bad_sha_denied(self):
        with self.assertRaises(pin.PromotionError): pin.verify_source_qualification("abc", 42, lambda path: {})

    def test_bad_run_id_denied(self):
        with self.assertRaises(pin.PromotionError): pin.verify_source_qualification(SHA, -1, lambda path: {})


class ExactProtectedPin(unittest.TestCase):
    def test_main_protected_workflows_have_consistent_immutable_sha(self):
        old, edits = pin.prepare(ROOT, SHA)
        self.assertEqual(old, SHA)
        self.assertEqual(len(edits), 2)
        self.assertEqual(edits[0][1].count(SHA), 2)
        self.assertEqual(edits[1][1].count(SHA), 3)

    def test_unrelated_companion_sha_unchanged(self):
        _, edits = pin.prepare(ROOT, SHA)
        for _, s in edits:
            self.assertIn("a027ef885c803a1b1216c62c8a4d6190a19cd833", s)

    def test_malicious_dynamic_event_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d) / ".github/workflows"
            base.mkdir(parents=True)
            for name, _ in pin.WORKFLOWS:
                (Path(d) / name).write_text((ROOT / name).read_text(encoding="utf-8"),
                                            encoding="utf-8")
            native = Path(d) / pin.WORKFLOWS[0][0]
            native.write_text(native.read_text(encoding="utf-8").replace(
                "  workflow_dispatch:", "  pull_request:\n  workflow_dispatch:"), encoding="utf-8")
            with self.assertRaises(pin.PromotionError): pin.prepare(Path(d), SHA)

    def test_mismatched_policy_source_denied(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d) / ".github/workflows"
            base.mkdir(parents=True)
            for name, _ in pin.WORKFLOWS:
                (Path(d) / name).write_text((ROOT / name).read_text(encoding="utf-8"),
                                            encoding="utf-8")
            policy = Path(d) / pin.WORKFLOWS[1][0]
            policy.write_text(policy.read_text(encoding="utf-8").replace(
                SHA, OLD, 1), encoding="utf-8")
            with self.assertRaises(pin.PromotionError): pin.prepare(Path(d), SHA)


if __name__ == "__main__":
    unittest.main()

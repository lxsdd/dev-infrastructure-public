"""Synthetic-only checks for release-gate contract; never touch music files."""
import copy
import unittest
from metadata_cue_gate import PlanRejected, validate_plan

ZERO = "0" * 64
ONE = "1" * 64


def plan(scope="physical_tags", changed=False):
    return {
        "artifact_id": "synthetic:track-0001",
        "scope": scope,
        "before_sha256": ZERO,
        "after_sha256": ONE if changed else ZERO,
        "intended_write": changed,
        "approved": changed,
        "provenance": {
            "source": "user_review",
            "reference": "synthetic:review-1",
            "license_cleared": True,
        },
    }


class SafetyGateTests(unittest.TestCase):
    def test_noop_all_scopes(self):
        for scope in ("physical_tags", "embedded_cue", "external_cue"):
            with self.subTest(scope=scope):
                result = validate_plan(plan(scope))
                self.assertEqual(result["decision"], "NO_OP")
                self.assertFalse(result["would_write"])
                self.assertEqual(result["scope"], scope)

    def test_explicit_change_all_scopes(self):
        for scope in ("physical_tags", "embedded_cue", "external_cue"):
            with self.subTest(scope=scope):
                result = validate_plan(plan(scope, changed=True))
                self.assertEqual(result["decision"], "REVIEWED_CHANGE")
                self.assertTrue(result["would_write"])
                self.assertEqual(result["scope"], scope)

    def test_reject_unsafe_variants(self):
        mutations = [
            lambda x: x.update(intended_write=True),
            lambda x: x.update(scope="physical_tags+embedded_cue"),
            lambda x: x.update(artifact_id="C:/private/music.mp3"),
            lambda x: x.update(before_sha256="BAD"),
            lambda x: x.update(approved=1),
            lambda x: x["provenance"].update(license_cleared=False),
            lambda x: x["provenance"].update(source="unverified"),
            lambda x: x.pop("provenance"),
        ]
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                value = plan()
                mutation(value)
                with self.assertRaises(PlanRejected):
                    validate_plan(value)

    def test_reject_unapproved_change_and_hidden_write(self):
        for key, value in (("approved", False), ("intended_write", False)):
            candidate = plan(changed=True)
            candidate[key] = value
            with self.assertRaises(PlanRejected):
                validate_plan(candidate)

    def test_reject_extra_fields(self):
        candidate = plan()
        candidate["real_path"] = "/home/user/music.mp3"
        with self.assertRaises(PlanRejected):
            validate_plan(candidate)


if __name__ == "__main__":
    unittest.main()

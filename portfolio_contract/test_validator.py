import copy
import unittest

from validator import validate

A = "a" * 40
B = "b" * 40
C = "c" * 40


def fixtures():
    projects = {
        "schema_version": 1,
        "repositories": [
            {"full_name": "example/foobar", "area": "foobar",
             "family": "example-foobar", "default_branch_head": A},
            {"full_name": "example/desktop", "area": "other",
             "family": "example-desktop", "default_branch_head": B},
        ],
    }
    prs = [
        {"repo": "example/foobar", "number": 1, "head_sha": A, "base_sha": B,
         "area": "foobar", "family": "example-foobar",
         "url": "https://github.com/example/foobar/pull/1", "draft": True},
        {"repo": "example/desktop", "number": 3, "head_sha": B, "base_sha": C,
         "area": "other", "family": "example-desktop",
         "url": "https://github.com/example/desktop/pull/3", "draft": False},
    ]
    snapshot = {
        "schema_version": 1,
        "counts": {"repositories": 2, "open_pull_requests": 2,
                   "draft_pull_requests": 1},
        "pull_requests": prs,
    }
    decisions = {"schema_version": 1, "decisions": [
        {"repo": p["repo"], "number": p["number"], "head_sha": p["head_sha"],
         "state": "unreviewed", "acceptance": "NOT_TESTED", "review_evidence": [],
         "integration_commit": None, "replacement": None} for p in prs
    ]}
    initiatives = {"schema_version": 1, "initiatives": [
        {"id": "EX-1", "area": "foobar", "status": "pending",
         "references": ["example/foobar#1"], "acceptance": ["host test"]},
    ]}
    return projects, snapshot, decisions, initiatives


class PreservationContractTests(unittest.TestCase):
    def setUp(self):
        self.docs = fixtures()

    def validate(self, docs=None):
        return validate(*(self.docs if docs is None else docs))

    def test_valid_synthetic_snapshot(self):
        self.assertEqual(self.validate(), {
            "repositories": 2, "pull_requests": 2, "initiatives": 1})

    def test_pr_disappeared(self):
        docs = copy.deepcopy(self.docs)
        docs[2]["decisions"].pop()
        with self.assertRaises(ValueError):
            self.validate(docs)

    def test_duplicate_identity(self):
        docs = copy.deepcopy(self.docs)
        docs[1]["pull_requests"].append(docs[1]["pull_requests"][0])
        docs[1]["counts"]["open_pull_requests"] = 3
        docs[1]["counts"]["draft_pull_requests"] = 2
        with self.assertRaises(ValueError):
            self.validate(docs)

    def test_rewritten_pr_head(self):
        docs = copy.deepcopy(self.docs)
        docs[2]["decisions"][0]["head_sha"] = C
        with self.assertRaises(ValueError):
            self.validate(docs)

    def test_unproven_integration(self):
        docs = copy.deepcopy(self.docs)
        docs[2]["decisions"][0]["state"] = "already_integrated"
        with self.assertRaises(ValueError):
            self.validate(docs)

    def test_unproven_supersession(self):
        docs = copy.deepcopy(self.docs)
        docs[2]["decisions"][0]["state"] = "consolidate"
        docs[2]["decisions"][0]["review_evidence"] = ["reviewed source"]
        with self.assertRaises(ValueError):
            self.validate(docs)

    def test_fake_completed_workstream(self):
        docs = copy.deepcopy(self.docs)
        docs[3]["initiatives"][0]["status"] = "completed"
        with self.assertRaises(ValueError):
            self.validate(docs)

    def test_unreviewed_is_not_pass(self):
        docs = copy.deepcopy(self.docs)
        docs[2]["decisions"][0]["acceptance"] = "PASS"
        with self.assertRaises(ValueError):
            self.validate(docs)

    def test_wrong_product_family(self):
        docs = copy.deepcopy(self.docs)
        docs[1]["pull_requests"][0]["family"] = "example-desktop"
        with self.assertRaises(ValueError):
            self.validate(docs)


if __name__ == "__main__":
    unittest.main()

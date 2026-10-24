import copy
import unittest

from coordination import ownership_decision

A = "a" * 40
B = "b" * 40


def work():
    return dict(repository="example/project", branch="feature/example", expected_head=A)


def registry(mode="AGENT", claim=None):
    return [dict(repository="example/project", branch="feature/example",
                 head_sha=A, mode=mode, claim=claim)]


class BranchOwnershipContractTests(unittest.TestCase):
    def decide(self, assignments=None, actor="AGENT", task=None, **kw):
        return ownership_decision(
            task or work(), actor=actor,
            assignments=registry() if assignments is None else assignments,
            actual_head=kw.pop("actual_head", A),
            expected_ledger_sha=kw.pop("expected_ledger_sha", B),
            observed_ledger_sha=kw.pop("observed_ledger_sha", B),
            actual_pr_state=kw.pop("actual_pr_state", "open"))

    def test_agent_lane_can_request_claim(self):
        self.assertEqual(self.decide(), "READY_TO_CLAIM")

    def test_chat_lane_can_request_claim(self):
        self.assertEqual(self.decide(registry("CHAT"), actor="CHAT"),
                         "READY_TO_CLAIM")

    def test_agent_cannot_take_chat_lane(self):
        self.assertEqual(self.decide(registry("CHAT")),
                         "OTHER_LANE_OWNS_BRANCH")

    def test_chat_cannot_take_agent_lane(self):
        self.assertEqual(self.decide(registry("AGENT"), actor="CHAT"),
                         "OTHER_LANE_OWNS_BRANCH")

    def test_free_lane_needs_claim_for_each_actor(self):
        for actor in ("CHAT", "AGENT"):
            with self.subTest(actor=actor):
                self.assertEqual(self.decide(registry("FREI"), actor=actor),
                                 "READY_TO_CLAIM")

    def test_blocked_never_claimed(self):
        self.assertEqual(self.decide(registry("BLOCKIERT")), "BLOCKED")

    def test_active_claim_requires_reconciliation_even_same_actor(self):
        held = dict(holder="AGENT", token="example-1", expires_at=1)
        self.assertEqual(self.decide(registry("AGENT", claim=held)),
                         "RECONCILE_EXISTING_CLAIM")

    def test_duplicate_branch_identity_is_rejected(self):
        rows = registry() + registry()
        self.assertEqual(self.decide(rows), "DUPLICATE_ASSIGNMENT")

    def test_missing_assignment_fails_closed(self):
        self.assertEqual(self.decide([]), "MISSING_ASSIGNMENT")

    def test_wrong_live_source_head_rejected(self):
        self.assertEqual(self.decide(actual_head=B), "STALE_HEAD")

    def test_unreconciled_ledger_sha_rejected(self):
        self.assertEqual(self.decide(observed_ledger_sha=A), "STALE_LEDGER")

    def test_invalid_ledger_sha_rejected(self):
        self.assertEqual(self.decide(expected_ledger_sha="pending"),
                         "INVALID_LEDGER_SHA")

    def test_missing_claim_field_fails_closed(self):
        rows = registry()
        del rows[0]["claim"]
        self.assertEqual(self.decide(rows), "INVALID_ASSIGNMENT")

    def test_unverified_live_pr_state_blocks_claim(self):
        self.assertEqual(self.decide(actual_pr_state=None), "PR_STATE_UNVERIFIED")

    def test_closed_or_merged_live_pr_blocks_claim(self):
        for state in ("closed", "merged"):
            with self.subTest(state=state):
                self.assertEqual(self.decide(actual_pr_state=state), "PR_NOT_OPEN")

    def test_merged_historical_ledger_snapshot_blocks_spoofed_open_state(self):
        rows = registry("AGENT")
        rows[0]["remote_status_snapshot"] = dict(
            state="closed", merged=True, merged_at="2026-10-22T20:52:55Z")
        self.assertEqual(self.decide(rows, actual_pr_state="open"),
                         "PR_SNAPSHOT_CONFLICT")

    def test_invalid_ledger_pr_snapshot_rejected(self):
        rows = registry("AGENT")
        rows[0]["remote_status_snapshot"] = "open"
        self.assertEqual(self.decide(rows), "INVALID_ASSIGNMENT")

    def test_unknown_actor_rejected(self):
        self.assertEqual(self.decide(actor="SCHEDULED"), "INVALID_ACTOR")

    def test_unknown_mode_rejected(self):
        self.assertEqual(self.decide(registry("AUTO")), "INVALID_ASSIGNMENT")

    def test_wrong_work_branch_does_not_fall_back(self):
        candidate = work()
        candidate["branch"] = "feature/other"
        self.assertEqual(self.decide(task=candidate), "MISSING_ASSIGNMENT")


if __name__ == "__main__":
    unittest.main()

"""Synthetic-only P0/fairness tests: no actual project identities or GitHub writes."""
import unittest

from selection import select_next

HEAD = "a" * 40
LEDGER = "b" * 40


def candidate(name, family, priority="P1", last=0, **changes):
    result = {
        "task_id": name,
        "family": family,
        "priority": priority,
        "last_success_at": last,
        "reproduction_evidence": "reproducible in-memory negative test",
        "actual_head": HEAD,
        "actual_pr_state": "open",
        "task": {
            "repository": "example/portfolio",
            "branch": "work/" + name,
            "expected_head": HEAD,
            "state": "QUEUED",
            "source_visibility": "public",
            "runner_kind": "chatgpt_subscription_task",
        },
    }
    result.update(changes)
    return result


class PriorityAndFairnessTests(unittest.TestCase):
    def choose(self, *candidates, **kwargs):
        assignments = kwargs.pop("assignments", [
            {"repository": c["task"]["repository"],
             "branch": c["task"]["branch"], "head_sha": HEAD,
             "mode": "FREI", "claim": None}
            for c in candidates
        ])
        return select_next(
            list(candidates), assignments=assignments,
            expected_ledger_sha=kwargs.pop("expected_ledger_sha", LEDGER),
            observed_ledger_sha=kwargs.pop("observed_ledger_sha", LEDGER),
            plan_capacity_available=kwargs.pop("plan_capacity_available", True),
            actor=kwargs.pop("actor", "AGENT"),
            leases=kwargs.pop("leases", []),
            now=kwargs.pop("now", 1000))

    def test_p0_beats_older_p1(self):
        result = self.choose(candidate("first", "audio", "P1", 0),
                             candidate("urgent", "metadata", "P0", 999))
        self.assertEqual(result["task_id"], "urgent")
        self.assertEqual(result["status"], "READY_TO_CLAIM")

    def test_same_priority_oldest_family_wins(self):
        result = self.choose(candidate("recent", "audio", "P0", 900),
                             candidate("neglected", "metadata", "P0", 50))
        self.assertEqual(result["task_id"], "neglected")

    def test_order_independent_lexical_tie_break(self):
        first = candidate("zulu", "zeta", "P0", 500)
        second = candidate("alpha", "alpha", "P0", 500)
        self.assertEqual(self.choose(first, second)["task_id"], "alpha")
        self.assertEqual(self.choose(second, first)["task_id"], "alpha")

    def test_unreproduced_p0_label_does_not_outrank_p1(self):
        unproven = candidate("unproven", "metadata", "P0", 0,
                             reproduction_evidence="")
        result = self.choose(unproven, candidate("verified", "audio", "P1", 800))
        self.assertEqual(result["task_id"], "verified")
        self.assertIn({"task_id": "unproven", "reason": "NOT_REPRODUCED"},
                      result["blocked"])

    def test_unverified_p0_pr_does_not_block_verified_p1(self):
        hidden = candidate("hidden", "metadata", "P0", 0,
                           actual_pr_state=None)
        result = self.choose(hidden, candidate("verified", "audio", "P1", 900))
        self.assertEqual(result["task_id"], "verified")
        self.assertIn({"task_id": "hidden", "reason": "PR_STATE_UNVERIFIED"},
                      result["blocked"])

    def test_chat_owned_p0_does_not_override_source_ownership(self):
        blocked = candidate("reserved", "metadata", "P0")
        allowed = candidate("available", "audio", "P1")
        assignments = [
            {"repository": "example/portfolio", "branch": "work/reserved",
             "head_sha": HEAD, "mode": "CHAT", "claim": None},
            {"repository": "example/portfolio", "branch": "work/available",
             "head_sha": HEAD, "mode": "FREI", "claim": None}
        ]
        result = self.choose(blocked, allowed, assignments=assignments)
        self.assertEqual(result["task_id"], "available")
        self.assertIn({"task_id": "reserved",
                       "reason": "OTHER_LANE_OWNS_BRANCH"}, result["blocked"])

    def test_existing_claim_cannot_be_stolen(self):
        item = candidate("claimed", "audio", "P0")
        entries = [{"repository": "example/portfolio", "branch": "work/claimed",
                    "head_sha": HEAD, "mode": "FREI",
                    "claim": {"status": "ACTIVE"}}]
        result = self.choose(item, assignments=entries)
        self.assertEqual(result["status"], "NO_ELIGIBLE_TASK")
        self.assertEqual(result["blocked"][0]["reason"],
                         "RECONCILE_EXISTING_CLAIM")

    def test_stale_private_ledger_never_selected(self):
        result = self.choose(candidate("task", "audio", "P0"),
                             observed_ledger_sha=HEAD)
        self.assertEqual(result["status"], "NO_ELIGIBLE_TASK")
        self.assertEqual(result["blocked"][0]["reason"], "STALE_LEDGER")

    def test_plan_capacity_is_an_absolute_gate(self):
        result = self.choose(candidate("task", "audio", "P0"),
                             plan_capacity_available=False)
        self.assertEqual(result["status"], "NO_ELIGIBLE_TASK")
        self.assertEqual(result["blocked"][0]["reason"], "PLAN_LIMIT_HOLD")

    def test_paid_candidate_does_not_override_free_p1(self):
        blocked = candidate("paid", "metadata", "P0", 0)
        blocked["task"]["requires_billed_compute"] = True
        result = self.choose(blocked, candidate("free", "audio", "P1", 800))
        self.assertEqual(result["task_id"], "free")
        self.assertIn({"task_id": "paid",
                       "reason": "PAID_PROVIDER_FORBIDDEN"}, result["blocked"])

    def test_duplicate_task_id_is_ambiguous(self):
        row = candidate("same", "audio")
        result = self.choose(row, row)
        self.assertEqual(result["status"], "AMBIGUOUS_CANDIDATES")

    def test_duplicate_branch_is_ambiguous(self):
        a = candidate("first", "audio")
        b = candidate("second", "metadata")
        b["task"]["branch"] = a["task"]["branch"]
        self.assertEqual(self.choose(a, b)["status"],
                         "AMBIGUOUS_CANDIDATES")

    def test_family_history_conflict_fail_closed(self):
        result = self.choose(candidate("a", "audio", "P0", 100),
                             candidate("b", "audio", "P0", 200))
        self.assertEqual(result["status"], "INCONSISTENT_FAMILY_HISTORY")

    def test_missing_or_future_last_progress_rejected(self):
        self.assertEqual(self.choose(candidate("a", "audio",
                                                     last=None))["status"],
                         "INVALID_CANDIDATES")
        self.assertEqual(self.choose(candidate("a", "audio",
                                                     last=1001))["status"],
                         "INVALID_CANDIDATES")

    def test_unexpected_priority_or_boolean_last_rejected(self):
        self.assertEqual(self.choose(candidate("a", "audio",
                                                     priority="P9"))["status"],
                         "INVALID_CANDIDATES")
        self.assertEqual(self.choose(candidate("a", "audio",
                                                     last=True))["status"],
                         "INVALID_CANDIDATES")

    def test_empty_or_malformed_input(self):
        self.assertEqual(select_next([], assignments=[], expected_ledger_sha=LEDGER,
                                     observed_ledger_sha=LEDGER,
                                     plan_capacity_available=True)["status"],
                         "NO_CANDIDATES")
        self.assertEqual(select_next([None], assignments=[],
                                     expected_ledger_sha=LEDGER,
                                     observed_ledger_sha=LEDGER,
                                     plan_capacity_available=True)["status"],
                         "INVALID_CANDIDATES")

    def test_ready_only_means_prospective_claim(self):
        result = self.choose(candidate("task", "audio", "P0"))
        self.assertEqual(result["status"], "READY_TO_CLAIM")
        self.assertNotIn("claim", result)


if __name__ == "__main__":
    unittest.main()

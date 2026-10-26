"""Adversarial synthetic tests for exact-HEAD, multi-workflow CI attestation."""
import copy
import unittest

from qualification import qualification_bundle_decision

SHA = "a" * 40
DIFFERENT = "b" * 40


def requirements():
    return [
        dict(role="contract_push", event="push",
             workflow="Portfolio contract", required_jobs=["contract"]),
        dict(role="contract_pr", event="pull_request",
             workflow="Portfolio contract", required_jobs=["contract"]),
        dict(role="baseline_pr", event="pull_request",
             workflow="Public baseline",
             required_jobs=["synthetic-contract", "shared-source-drift"]),
    ]


def passed_job(name):
    return dict(name=name, status="completed", conclusion="success",
                executed_steps=5)


def run(role, run_id, event, workflow, names):
    return dict(role=role, run_id=run_id, event=event, workflow=workflow,
                head_sha=SHA, status="completed", conclusion="success",
                jobs=[passed_job(name) for name in names], artifacts=[])


def witnesses():
    return [
        run("contract_push", 101, "push", "Portfolio contract", ["contract"]),
        run("contract_pr", 102, "pull_request", "Portfolio contract", ["contract"]),
        run("baseline_pr", 103, "pull_request", "Public baseline",
            ["synthetic-contract", "shared-source-drift"]),
    ]


class QualificationBundleTests(unittest.TestCase):
    def check(self, w=None, req=None, sha=SHA):
        return qualification_bundle_decision(
            witnesses() if w is None else w, expected_head=sha,
            required_runs=requirements() if req is None else req)

    def test_three_independent_exact_commit_runs_pass(self):
        self.assertEqual(self.check(), "PASS")

    def test_push_missing_cannot_be_replaced_with_pr(self):
        self.assertEqual(self.check(witnesses()[1:]), "NOT_RUN")

    def test_baseline_missing_cannot_be_replaced_with_contract(self):
        self.assertEqual(self.check(witnesses()[:2]), "NOT_RUN")

    def test_zero_runs_are_not_a_failed_build_or_pass(self):
        self.assertEqual(self.check([]), "NOT_RUN")

    def test_push_event_relabelled_as_pr_rejected(self):
        rows = witnesses()
        rows[0]["event"] = "pull_request"
        self.assertEqual(self.check(rows), "WRONG_WORKFLOW")

    def test_baseline_workflow_mismatch_rejected(self):
        rows = witnesses()
        rows[2]["workflow"] = "Portfolio contract"
        self.assertEqual(self.check(rows), "WRONG_WORKFLOW")

    def test_wrong_public_commit_rejected_even_if_green(self):
        rows = witnesses()
        rows[1]["head_sha"] = DIFFERENT
        self.assertEqual(self.check(rows), "STALE_HEAD")

    def test_duplicate_run_id_rejected(self):
        rows = witnesses()
        rows[2]["run_id"] = rows[0]["run_id"]
        self.assertEqual(self.check(rows), "AMBIGUOUS")

    def test_duplicate_role_rejected(self):
        rows = witnesses()
        rows[2]["role"] = rows[0]["role"]
        self.assertEqual(self.check(rows), "AMBIGUOUS")

    def test_unknown_workflow_role_is_not_silently_ignored(self):
        rows = witnesses()
        rows.append(run("unreviewed", 104, "push", "Unknown", ["contract"]))
        self.assertEqual(self.check(rows), "UNREVIEWED_RUN")

    def test_pending_not_pass(self):
        rows = witnesses()
        rows[0]["status"] = "in_progress"
        self.assertEqual(self.check(rows), "PENDING")

    def test_run_failure_not_pass(self):
        rows = witnesses()
        rows[2]["conclusion"] = "failure"
        self.assertEqual(self.check(rows), "FAIL")

    def test_required_job_missing_not_pass(self):
        rows = witnesses()
        rows[2]["jobs"] = [passed_job("synthetic-contract")]
        self.assertEqual(self.check(rows), "NOT_RUN")

    def test_failed_real_job_not_pass(self):
        rows = witnesses()
        rows[2]["jobs"][1]["conclusion"] = "failure"
        self.assertEqual(self.check(rows), "FAIL")

    def test_zero_step_admission_block_not_pass(self):
        rows = witnesses()
        rows[0]["jobs"][0]["executed_steps"] = 0
        self.assertEqual(self.check(rows), "NOT_RUN")

    def test_boolean_step_count_rejected(self):
        rows = witnesses()
        rows[2]["jobs"][0]["executed_steps"] = True
        self.assertEqual(self.check(rows), "NOT_RUN")

    def test_missing_artifact_inventory_not_pass(self):
        rows = witnesses()
        del rows[1]["artifacts"]
        self.assertEqual(self.check(rows), "ARTIFACTS_NOT_VERIFIED")

    def test_null_artifact_inventory_not_pass(self):
        rows = witnesses()
        rows[1]["artifacts"] = None
        self.assertEqual(self.check(rows), "ARTIFACTS_NOT_VERIFIED")

    def test_any_uploaded_artifact_is_a_hard_block(self):
        rows = witnesses()
        rows[2]["artifacts"] = [dict(name="releaseable-binary.zip")]
        self.assertEqual(self.check(rows), "ARTIFACTS_PRESENT")

    def test_boolean_run_id_is_not_positive_integer(self):
        rows = witnesses()
        rows[0]["run_id"] = True
        self.assertEqual(self.check(rows), "INVALID_ATTESTATION")

    def test_nonmapping_witness_rejected(self):
        rows = witnesses()
        rows[0] = []
        self.assertEqual(self.check(rows), "INVALID_ATTESTATION")

    def test_unexpected_witness_container_rejected(self):
        self.assertEqual(self.check({}), "INVALID_ATTESTATION")

    def test_missing_expected_head_invalid(self):
        self.assertEqual(self.check(sha=""), "INVALID_EXPECTATION")

    def test_wrong_length_expected_head_invalid(self):
        self.assertEqual(self.check(sha="a" * 39), "INVALID_EXPECTATION")

    def test_missing_requirements_invalid(self):
        self.assertEqual(self.check(req=[]), "INVALID_EXPECTATION")

    def test_duplicate_requirement_role_invalid(self):
        requirements_set = requirements()
        requirements_set[2]["role"] = requirements_set[0]["role"]
        self.assertEqual(self.check(req=requirements_set), "INVALID_EXPECTATION")

    def test_duplicate_workflow_event_identity_invalid(self):
        requirements_set = requirements()
        requirements_set[2]["workflow"] = "Portfolio contract"
        self.assertEqual(self.check(req=requirements_set), "INVALID_EXPECTATION")

    def test_duplicate_required_job_invalid(self):
        requirements_set = requirements()
        requirements_set[2]["required_jobs"] = ["synthetic-contract"] * 2
        self.assertEqual(self.check(req=requirements_set), "INVALID_EXPECTATION")

    def test_malformed_requirement_row_invalid(self):
        self.assertEqual(self.check(req=[None]), "INVALID_EXPECTATION")

    def test_unreviewed_event_invalid(self):
        requirements_set = requirements()
        requirements_set[0]["event"] = "repository_dispatch"
        self.assertEqual(self.check(req=requirements_set), "INVALID_EXPECTATION")

    def test_invalid_run_id_rejected(self):
        rows = witnesses()
        rows[0]["run_id"] = 0
        self.assertEqual(self.check(rows), "INVALID_ATTESTATION")

    def test_missing_jobs_inventory_cannot_pass(self):
        rows = witnesses()
        del rows[2]["jobs"]
        self.assertEqual(self.check(rows), "NOT_RUN")

    def test_real_host_step_failure_cannot_be_hidden_by_two_other_green_runs(self):
        rows = witnesses()
        rows[2]["jobs"][1]["status"] = "completed"
        rows[2]["jobs"][1]["executed_steps"] = 3
        rows[2]["jobs"][1]["conclusion"] = "failure"
        self.assertEqual(self.check(rows), "FAIL")


if __name__ == "__main__":
    unittest.main()

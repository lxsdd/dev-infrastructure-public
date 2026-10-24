import unittest

from scheduler import ci_decision, dispatch_decision

SHA = "a" * 40
NEW = "b" * 40


def task(**changes):
    data = dict(repository="example/foobar", branch="work/test", expected_head=SHA,
                state="QUEUED", source_visibility="public", runner_kind="chatgpt_subscription_task")
    data.update(changes)
    return data


def job(**changes):
    data = dict(name="contract", status="completed", conclusion="success",
                executed_steps=5)
    data.update(changes)
    return data


class AgentDispatchContractTests(unittest.TestCase):
    def check(self, item=None, **kwargs):
        item = item or task()
        ownership = kwargs.pop("ownership_assignments", [
            dict(repository=item["repository"], branch=item["branch"],
                 head_sha=item["expected_head"], mode="AGENT", claim=None)])
        return dispatch_decision(
            item, actual_head=kwargs.pop("actual_head", SHA),
            plan_capacity_available=kwargs.pop("plan_capacity_available", True),
            now=kwargs.pop("now", 100), leases=kwargs.pop("leases", ()),
            actor=kwargs.pop("actor", "AGENT"),
            ownership_assignments=ownership,
            expected_ledger_sha=kwargs.pop("expected_ledger_sha", NEW),
            observed_ledger_sha=kwargs.pop("observed_ledger_sha", NEW))

    def test_ready_public_pilot(self):
        self.assertEqual(self.check(), "READY_TO_CLAIM")

    def test_dispatch_without_owned_branch_must_stop(self):
        self.assertEqual(self.check(ownership_assignments=None), "INVALID_LEDGER")

    def test_dispatch_respects_chat_ownership(self):
        rows = [dict(repository="example/foobar", branch="work/test",
                     head_sha=SHA, mode="CHAT", claim=None)]
        self.assertEqual(self.check(ownership_assignments=rows),
                         "OTHER_LANE_OWNS_BRANCH")

    def test_dispatch_cannot_skip_stale_ledger_reconciliation(self):
        self.assertEqual(self.check(observed_ledger_sha=SHA), "STALE_LEDGER")

    def test_stale_sha_never_dispatches(self):
        self.assertEqual(self.check(actual_head=NEW), "STALE_HEAD")

    def test_same_branch_active_lease_prevents_double_agent(self):
        leases = [dict(repository="example/foobar", branch="work/test",
                       state="RUNNING", expires_at=150)]
        self.assertEqual(self.check(leases=leases), "ALREADY_RUNNING")

    def test_expired_lease_requires_remote_reconciliation(self):
        leases = [dict(repository="example/foobar", branch="work/test",
                       state="RUNNING", expires_at=99)]
        self.assertEqual(self.check(leases=leases), "RECONCILE_REMOTE")

    def test_subscription_plan_capacity_is_a_hard_gate(self):
        self.assertEqual(self.check(plan_capacity_available=False), "PLAN_LIMIT_HOLD")

    def test_external_paid_api_is_forbidden(self):
        self.assertEqual(self.check(task(requires_paid_api=True)), "PAID_PROVIDER_FORBIDDEN")

    def test_paid_compute_is_forbidden(self):
        self.assertEqual(self.check(task(requires_billed_compute=True)), "PAID_PROVIDER_FORBIDDEN")

    def test_no_automatic_owner_approval(self):
        self.assertEqual(self.check(task(owner_approval_required=True)), "BLOCKED_OWNER")

    def test_private_source_cannot_use_public_ci(self):
        self.assertEqual(self.check(task(source_visibility="private",
                                         public_ci_repo="example/foobar-public")), "PRIVACY_BLOCK")

    def test_three_identical_failures_halt(self):
        self.assertEqual(self.check(task(same_failure_count=3)), "REPEATED_FAILURE_HOLD")

    def test_done_never_reopens(self):
        self.assertEqual(self.check(task(state="DONE")), "ALREADY_DONE")

    def test_a_ci_runner_is_not_an_agent(self):
        self.assertEqual(self.check(task(runner_kind="github_actions")), "INVALID_RUNNER")


class CiAttestationContractTests(unittest.TestCase):
    def check(self, jobs, sha=SHA, required=("contract",)):
        return ci_decision({"head_sha": sha, "jobs": jobs},
                           expected_head=SHA, required_jobs=required)

    def test_exact_commit_real_steps_pass(self):
        self.assertEqual(self.check([job()]), "PASS")

    def test_zero_step_admission_is_not_pass(self):
        self.assertEqual(self.check([job(executed_steps=0)]), "NOT_RUN")

    def test_wrong_source_is_not_pass(self):
        self.assertEqual(self.check([job()], sha=NEW), "STALE_HEAD")

    def test_required_job_missing_is_not_pass(self):
        self.assertEqual(self.check([job()], required=("contract", "host")), "NOT_RUN")

    def test_real_host_failure_overrides_green_contract(self):
        self.assertEqual(self.check([job(), job(name="host", conclusion="failure")],
                                    required=("contract", "host")), "FAIL")

    def test_pending_not_pass(self):
        self.assertEqual(self.check([job(status="in_progress")]), "PENDING")

    def test_duplicate_job_identity_is_ambiguous(self):
        self.assertEqual(self.check([job(), job()]), "AMBIGUOUS")


if __name__ == "__main__":
    unittest.main()

import unittest

from scheduler import ci_decision, dispatch_decision

SHA = "a" * 40
NEW = "b" * 40


def task(**changes):
    data = dict(repository="example/foobar", branch="work/test", expected_head=SHA,
                state="QUEUED", source_visibility="public", runner_kind="managed_agent")
    data.update(changes)
    return data


def job(**changes):
    data = dict(name="contract", status="completed", conclusion="success",
                executed_steps=5)
    data.update(changes)
    return data


class AgentDispatchContractTests(unittest.TestCase):
    def check(self, item=None, **kwargs):
        return dispatch_decision(item or task(), actual_head=kwargs.pop("actual_head", SHA),
                                 budget_available=kwargs.pop("budget_available", True),
                                 now=kwargs.pop("now", 100),
                                 leases=kwargs.pop("leases", ()))

    def test_ready_public_pilot(self):
        self.assertEqual(self.check(), "READY")

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

    def test_budget_is_a_hard_gate(self):
        self.assertEqual(self.check(budget_available=False), "BUDGET_HOLD")

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

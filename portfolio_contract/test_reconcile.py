"""Positive and adversarial synthetic evidence for branch and CI reconciliation."""
import copy
import unittest

from reconcile import reconcile_portfolio

A = "a" * 40
B = "b" * 40
C = "c" * 40
CTRL = ("example/control", "feature/draft", 3)


def entry(repo="example/product", pr=4, head=A, mode="CHAT", claim=None):
    return dict(repository=repo, branch="feature/draft", pr=pr,
                head_sha=head, mode=mode, claim=claim)


def observed(row, *, head=None, state="open", merged=False):
    return dict(repository=row["repository"], branch=row["branch"],
                pr=row["pr"], head_sha=head or row["head_sha"],
                state=state, merged=merged)


def registered():
    return [entry("example/control", 3), entry()]


def live():
    return [observed(row) for row in registered()]


def published_route(head=A):
    return dict(
        routes=[dict(id="public_contract", repository="example/product",
                     branch="feature/draft", pr=4, head_sha=head,
                     run_ids=[101, 102], artifacts_uploaded=False,
                     public_baseline_ci=dict(run_id=103, all_jobs="SUCCESS",
                                             artifacts_uploaded=False))],
        ownership=dict(public_contract_sha=head, public_contract_run=102))


def held(head=A):
    return dict(status="ACTIVE", worker="example-agent", run_id="sample-run",
                work_item="synthetic-regression", expected_source_head_sha=head,
                expires_at=1)


class PortfolioReconciliationTests(unittest.TestCase):
    def check(self, owners=None, observations=None, routes=None,
              control=CTRL):
        return reconcile_portfolio(
            registered() if owners is None else owners,
            live() if observations is None else observations,
            routes=routes, control_identity=control)

    def row(self, response, repo="example/product"):
        return next(row for row in response["entries"]
                    if row["repository"] == repo)

    def test_all_current_evidence_is_consistent_not_authority(self):
        result = self.check(routes=published_route())
        self.assertEqual(result["status"],
                         "RECORDED_STATE_CONSISTENT_NOT_AUTHORITY_TO_WRITE")
        self.assertEqual(result["registered"], 2)
        self.assertEqual(result["observed"], 2)

    def test_current_head_is_recorded_not_live_ci_qualified(self):
        self.assertEqual(self.check(routes=published_route())["public_route"],
                         "RECORDED_REFERENCE_COHERENT_NOT_LIVE_CI_VERIFIED")

    def test_without_route_does_not_fabricate_route_verification(self):
        self.assertEqual(self.check()["public_route"], "NOT_EVALUATED")

    def test_fresh_live_head_change_requires_reconciliation(self):
        records = live()
        records[1]["head_sha"] = B
        result = self.check(observations=records, routes=published_route())
        self.assertEqual(self.row(result)["status"], "STALE_SOURCE_HEAD")
        self.assertEqual(result["status"], "NEEDS_RECONCILIATION")

    def test_live_head_source_field_mismatch_not_marked_verified(self):
        records = live()
        records[1]["head_sha"] = B
        self.assertFalse(self.row(self.check(observations=records))[
            "source_head_verified"])

    def test_control_self_reference_is_not_a_source_write_failure(self):
        records = live()
        records[0]["head_sha"] = B
        self.assertEqual(self.row(self.check(observations=records),
                                  "example/control")["status"],
                         "CONTROL_SELF_REFERENCE_EXPECTED")

    def test_self_reference_exemption_not_available_to_other_project(self):
        records = live()
        records[1]["head_sha"] = B
        self.assertEqual(self.row(self.check(observations=records))[
            "status"], "STALE_SOURCE_HEAD")

    def test_self_reference_exemption_requires_chat_mode(self):
        owners = registered()
        owners[0]["mode"] = "FREI"
        records = live()
        records[0]["head_sha"] = B
        self.assertEqual(self.row(self.check(owners, records),
                                  "example/control")["status"],
                         "STALE_SOURCE_HEAD")

    def test_claimed_branch_is_never_available_for_takeover(self):
        owners = registered()
        owners[1]["mode"] = "FREI"
        owners[1]["claim"] = held()
        result = self.check(owners)
        self.assertEqual(self.row(result)["status"], "ACTIVE_CLAIM_NO_TAKEOVER")

    def test_expired_lease_cannot_be_auto_released(self):
        owners = registered()
        owners[1]["mode"] = "FREI"
        owners[1]["claim"] = held()
        owners[1]["claim"]["expires_at"] = -20000
        self.assertEqual(self.row(self.check(owners))["status"],
                         "ACTIVE_CLAIM_NO_TAKEOVER")

    def test_source_moved_during_active_claim_needs_reconciliation(self):
        owners = registered()
        owners[1]["mode"] = "FREI"
        owners[1]["claim"] = held()
        records = live()
        records[1]["head_sha"] = B
        result = self.check(owners, records)
        self.assertEqual(self.row(result)["status"], "CLAIM_SOURCE_CONFLICT")
        self.assertEqual(result["status"], "NEEDS_RECONCILIATION")

    def test_claim_registry_head_disagreement_is_detected(self):
        owners = registered()
        owners[1]["mode"] = "AGENT"
        owners[1]["claim"] = held(B)
        self.assertEqual(self.row(self.check(owners))["status"],
                         "CLAIM_LEDGER_CONFLICT")

    def test_claimed_source_drift_no_silent_lease_reuse(self):
        owners = registered()
        owners[1]["mode"] = "AGENT"
        owners[1]["head_sha"] = B
        owners[1]["claim"] = held(B)
        records = live()
        self.assertEqual(self.row(self.check(owners, records))["status"],
                         "CLAIM_SOURCE_CONFLICT")

    def test_closed_pr_demands_lifecycle_reconciliation(self):
        records = live()
        records[1]["state"] = "closed"
        self.assertEqual(self.row(self.check(observations=records))["status"],
                         "CLOSED_PR_RECONCILIATION_REQUIRED")

    def test_merged_pr_not_treated_as_open_branch(self):
        records = live()
        records[1]["state"] = "closed"
        records[1]["merged"] = True
        self.assertEqual(self.row(self.check(observations=records))["status"],
                         "MERGED_PR_RECONCILIATION_REQUIRED")

    def test_explicitly_blocked_merged_pr_is_archived(self):
        owners = registered()
        owners[1]["mode"] = "BLOCKIERT"
        records = live()
        records[1].update(state="closed", merged=True)
        result = self.check(owners, records)
        self.assertEqual(self.row(result)["status"],
                         "ARCHIVED_CLOSED_OR_MERGED_PR")

    def test_explicitly_blocked_closed_pr_is_archived(self):
        owners = registered()
        owners[1]["mode"] = "BLOCKIERT"
        records = live()
        records[1].update(state="closed", merged=False)
        self.assertEqual(self.row(self.check(owners, records))["status"],
                         "ARCHIVED_CLOSED_OR_MERGED_PR")

    def test_blocked_open_pr_does_not_become_claimable(self):
        owners = registered()
        owners[1]["mode"] = "BLOCKIERT"
        self.assertEqual(self.row(self.check(owners))["status"],
                         "BLOCKED_NO_WRITES")

    def test_free_branch_new_head_without_acceptance_is_flagged(self):
        owners = registered()
        owners[1]["mode"] = "FREI"
        owners[1]["last_completed"] = {"new_head_sha": B}
        self.assertEqual(self.row(self.check(owners))["status"],
                         "UNVERIFIED_FREE_HEAD")

    def test_free_branch_accepted_head_can_be_current(self):
        owners = registered()
        owners[1]["mode"] = "FREI"
        owners[1]["last_completed"] = {"new_head_sha": A}
        self.assertEqual(self.row(self.check(owners))["status"],
                         "CURRENT_OPEN_NO_CLAIM")

    def test_missing_observation_denies_consistency(self):
        result = self.check(observations=live()[:1])
        self.assertEqual(self.row(result)["status"], "UNVERIFIED_LIVE_PR")
        self.assertEqual(result["status"], "NEEDS_RECONCILIATION")

    def test_surplus_unregistered_live_pr_requires_registration(self):
        records = live()
        records.append(observed(entry("example/new", 15)))
        self.assertEqual(self.check(observations=records)["status"],
                         "UNREGISTERED_LIVE_PR")

    def test_duplicate_live_identity_denies_entire_snapshot(self):
        records = live()
        records.append(copy.deepcopy(records[0]))
        self.assertEqual(self.check(observations=records)["status"],
                         "DUPLICATE_IDENTITY")

    def test_duplicate_assignment_branch_denies_entire_snapshot(self):
        owners = registered()
        owners.append(entry(pr=25))
        self.assertEqual(self.check(owners)["status"], "DUPLICATE_IDENTITY")

    def test_duplicate_pr_number_across_two_branches_denies_all(self):
        owners = registered()
        other = entry(pr=4)
        other["branch"] = "feature/different"
        owners.append(other)
        self.assertEqual(self.check(owners)["status"], "DUPLICATE_IDENTITY")

    def test_duplicate_observed_pr_number_across_branches_denies_all(self):
        records = live()
        extra = copy.deepcopy(records[1])
        extra["branch"] = "feature/different"
        records.append(extra)
        self.assertEqual(self.check(observations=records)["status"],
                         "DUPLICATE_IDENTITY")

    def test_claimed_public_route_never_recorded_as_coherent(self):
        owners = registered()
        owners[1]["mode"] = "FREI"
        owners[1]["claim"] = held()
        result = self.check(owners, routes=published_route())
        self.assertEqual(result["public_route"], "ROUTE_EVIDENCE_INCOMPLETE")

    def test_unowned_public_route_never_recorded_as_coherent(self):
        owners = registered()
        owners[1]["mode"] = "BLOCKIERT"
        result = self.check(owners, routes=published_route())
        self.assertEqual(result["public_route"], "ROUTE_EVIDENCE_INCOMPLETE")

    def test_malformed_prior_completion_not_silently_ignored(self):
        owners = registered()
        owners[1]["last_completed"] = "already qualified"
        self.assertEqual(self.check(owners)["status"], "INVALID_INPUT")

    def test_invalid_prior_completion_source_hash_denied(self):
        owners = registered()
        owners[1]["last_completed"] = {"new_head_sha": "unknown"}
        self.assertEqual(self.check(owners)["status"], "INVALID_INPUT")

    def test_composed_realistic_snapshot_fails_without_guessing_action(self):
        owners = registered()
        owners.append(entry("example/archived", 5, mode="BLOCKIERT"))
        owners.append(entry("example/claimed", 6, mode="FREI", claim=held()))
        owners.append(entry("example/stale", 7))
        records = [observed(row) for row in owners]
        records[0]["head_sha"] = B
        records[2].update(state="closed", merged=True)
        records[4]["head_sha"] = C
        route = published_route(B)
        result = self.check(owners, records, route)
        self.assertEqual(result["status"], "NEEDS_RECONCILIATION")
        self.assertEqual(result["public_route"], "ROUTE_HEAD_MISMATCH")
        self.assertEqual(result["counts"]["CONTROL_SELF_REFERENCE_EXPECTED"], 1)
        self.assertEqual(result["counts"]["ARCHIVED_CLOSED_OR_MERGED_PR"], 1)
        self.assertEqual(result["counts"]["ACTIVE_CLAIM_NO_TAKEOVER"], 1)
        self.assertEqual(result["counts"]["STALE_SOURCE_HEAD"], 1)
        self.assertEqual(result["counts"]["CURRENT_OPEN_NO_CLAIM"], 1)

    def test_merged_open_inconsistent_github_snapshot_invalid(self):
        records = live()
        records[1]["merged"] = True
        self.assertEqual(self.check(observations=records)["status"],
                         "INVALID_INPUT")

    def test_boolean_pr_number_invalid(self):
        owners = registered()
        owners[1]["pr"] = True
        self.assertEqual(self.check(owners)["status"], "INVALID_INPUT")

    def test_missing_explicit_claim_field_invalid(self):
        owners = registered()
        del owners[1]["claim"]
        self.assertEqual(self.check(owners)["status"], "INVALID_INPUT")

    def test_malformed_active_claim_invalid(self):
        owners = registered()
        owners[1]["mode"] = "FREI"
        owners[1]["claim"] = dict(status="UNKNOWN")
        self.assertEqual(self.check(owners)["status"], "INVALID_INPUT")

    def test_chat_branch_cannot_carry_agent_claim(self):
        owners = registered()
        owners[1]["claim"] = held()
        self.assertEqual(self.check(owners)["status"], "INVALID_INPUT")

    def test_invalid_source_hash_in_ledger_denied(self):
        owners = registered()
        owners[1]["head_sha"] = "pending"
        self.assertEqual(self.check(owners)["status"], "INVALID_INPUT")

    def test_invalid_source_hash_in_observation_denied(self):
        records = live()
        records[1]["head_sha"] = "not-a-hash"
        self.assertEqual(self.check(observations=records)["status"],
                         "INVALID_INPUT")

    def test_stale_route_source_and_current_owner_cannot_pass(self):
        route = published_route(head=B)
        self.assertEqual(self.check(routes=route)["public_route"],
                         "ROUTE_HEAD_MISMATCH")
        self.assertEqual(self.check(routes=route)["status"],
                         "NEEDS_RECONCILIATION")

    def test_historical_run_ids_cannot_override_current_route_source(self):
        route = published_route(head=B)
        route["routes"][0]["previous_verified"] = [
            {"head_sha": A, "run_ids": [5001, 5002]}]
        self.assertEqual(self.check(routes=route)["public_route"],
                         "ROUTE_HEAD_MISMATCH")

    def test_route_wrong_ownership_head_detected(self):
        route = published_route()
        route["ownership"]["public_contract_sha"] = B
        self.assertEqual(self.check(routes=route)["public_route"],
                         "ROUTE_HEAD_MISMATCH")

    def test_route_missing_main_ci_run_denies_recorded_coherence(self):
        route = published_route()
        route["routes"][0]["public_baseline_ci"] = None
        self.assertEqual(self.check(routes=route)["public_route"],
                         "ROUTE_EVIDENCE_INCOMPLETE")

    def test_route_missing_upload_inventory_denies_recorded_coherence(self):
        route = published_route()
        del route["routes"][0]["artifacts_uploaded"]
        self.assertEqual(self.check(routes=route)["public_route"],
                         "ROUTE_EVIDENCE_INCOMPLETE")

    def test_duplicate_run_id_in_public_route_is_not_evidence(self):
        route = published_route()
        route["routes"][0]["run_ids"] = [101, 101]
        self.assertEqual(self.check(routes=route)["public_route"],
                         "ROUTE_EVIDENCE_INCOMPLETE")

    def test_baseline_run_cannot_be_reused_as_contract_run(self):
        route = published_route()
        route["routes"][0]["public_baseline_ci"]["run_id"] = 101
        self.assertEqual(self.check(routes=route)["public_route"],
                         "ROUTE_EVIDENCE_INCOMPLETE")

    def test_boolean_run_ids_are_not_evidence(self):
        route = published_route()
        route["routes"][0]["run_ids"] = [True, 102]
        self.assertEqual(self.check(routes=route)["public_route"],
                         "ROUTE_EVIDENCE_INCOMPLETE")

    def test_duplicate_public_contract_route_denies_coherence(self):
        route = published_route()
        route["routes"].append(copy.deepcopy(route["routes"][0]))
        self.assertEqual(self.check(routes=route)["public_route"],
                         "INVALID_ROUTE")

    def test_route_for_missing_repository_denies_coherence(self):
        route = published_route()
        route["routes"][0]["repository"] = "example/unknown"
        self.assertEqual(self.check(routes=route)["public_route"],
                         "ROUTE_IDENTITY_NOT_VERIFIED")

    def test_route_with_closed_live_pr_cannot_be_consistent(self):
        records = live()
        records[1].update(state="closed", merged=True)
        self.assertEqual(self.check(observations=records,
                                    routes=published_route())["public_route"],
                         "ROUTE_PR_NOT_OPEN")

    def test_route_missing_jobs_success_denies_coherence(self):
        route = published_route()
        route["routes"][0]["public_baseline_ci"]["all_jobs"] = "NOT_RUN"
        self.assertEqual(self.check(routes=route)["public_route"],
                         "ROUTE_EVIDENCE_INCOMPLETE")

    def test_route_with_artifacts_denies_coherence(self):
        route = published_route()
        route["routes"][0]["public_baseline_ci"]["artifacts_uploaded"] = True
        self.assertEqual(self.check(routes=route)["public_route"],
                         "ROUTE_EVIDENCE_INCOMPLETE")

    def test_empty_entire_observation_does_not_claim_current(self):
        result = self.check(observations=[])
        self.assertEqual(result["status"], "NEEDS_RECONCILIATION")
        self.assertEqual(result["observed"], 0)

    def test_nonlist_inputs_rejected(self):
        self.assertEqual(self.check(owners={})["status"], "INVALID_INPUT")
        self.assertEqual(self.check(observations={})["status"], "INVALID_INPUT")

    def test_invalid_control_identity_rejected(self):
        self.assertEqual(self.check(control=("invalid", "branch", True))[
            "status"], "INVALID_INPUT")

    def test_read_only_does_not_mutate_inputs(self):
        owners, observations, route = registered(), live(), published_route()
        baseline = copy.deepcopy((owners, observations, route))
        self.check(owners, observations, route)
        self.assertEqual((owners, observations, route), baseline)


if __name__ == "__main__":
    unittest.main()

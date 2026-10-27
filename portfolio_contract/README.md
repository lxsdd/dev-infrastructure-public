# Public portfolio preservation contract

This directory is an openly testable, **generic** implementation of the portfolio ledger invariants.

- No private GitHub repositories, branch names, PR titles, user paths, credentials or real project data are stored here.
- The fixture uses only fictitious `example/...` repository identities and artificial 40-character commit IDs.
- The script does not connect to GitHub, use an API token or mutate files. It validates caller-supplied in-memory JSON dictionaries.
- `scheduler.py` adds a side-effect-free **dispatch/attestation preflight**: exact-HEAD check, duplicate/expired lease reconciliation, hard zero-extra-cost policy (paid model APIs and compute forbidden), existing-subscription plan capacity and owner gates, private-to-public CI deny, and non-PASS for zero-step/missing/failing GitHub jobs. Fifty-three synthetic tests in `test_scheduler.py` enforce these fail-closed rules. Source-only CI now additionally requires a **verified empty GitHub run-artifact inventory** before returning PASS: missing artifact evidence, unexpectedly published ZIPs, boolean stand-ins for executed-step counts, duplicate required jobs, malformed CI job rows or job names, and PR-only run lookup gaps cannot be mistaken for success. An empty PR-only lookup of a push event remains `NOT_RUN` until the actual push run is independently located; **nothing here creates live sessions, leases, schedules or paid requests**.
- `scheduler.synthetic_ci_route_decision` additionally distinguishes public-source/source-cleared, synthetic/no-secret/no-artifact CI from quota-blocked private Actions. It rejects private-to-public source transfer *even if someone claims the source is cleared*, requires an exact source SHA, denies uncleared sources, personal data, secret use, publication and paid compute, and prefers public runners for eligible public source. Private-only validation is `PRIVATE_QUOTA_HOLD` unless private capacity is independently verified; public synthetic PASS does **not** replace execution of actual private tests. This is a pure routing proposal with synthetic tests, **not** a GitHub settings change, billing control, actual runner dispatcher, or authorization to copy private sources. Protected product-specific authenticated QA remains outside this generic secret-free contract.
- `coordination.py` adds a **CHAT / AGENT / FREI / BLOCKIERT** branch-ownership preflight, enforced by `scheduler.dispatch_decision`. It requires a freshly verified GitHub PR state of `open` before any source claim and rejects closed/merged PRs or a contradictory merged-historical registry snapshot. It rejects duplicate branch records, ambiguous/missing ownership, stale source and ledger SHAs, cross-lane takeovers, blocked work and *all* unreconciled claims, even when their timeout has elapsed. Returning `READY_TO_CLAIM` is **not permission to edit source**: the caller must first atomically write the claim into the private GitHub ledger using its just-fetched blob SHA, re-read the result, then recheck the actual branch HEAD. An expired claim is never silently stolen. Public tests use only fictitious identities.
- `selection.py` implements a **P0-before-P1, evidence-based, project-family fairness tie-break** as a second pure preflight. It evaluates concrete reproducibility evidence and the existing per-branch CHAT/AGENT/FREI/BLOCKIERT ownership and exact live-PR checks; among equally urgent claimable tasks it selects the family with the oldest independently supplied successful-work timestamp. A P0 initiative label alone cannot outrank a proven P1 defect. Ambiguous duplicate tasks, conflicting family history, stale private ledger state, unavailable plan capacity, unverified PR lifecycle, unexplained claims and paid sources are rejected or excluded. It does **not** fetch private progress, modify the scheduler, create a session, acquire a lock or guarantee unattended work. The caller must independently inspect the entire private initiative pool, recheck real GitHub state and acquire/reverify its CAS claim before writing source. Seventeen synthetic tests in `test_selection.py` exercise both positive priority and negative safety boundaries.
- The public infrastructure Draft also contains a narrowly scoped **publication-surface audit hardening**: recognize valid single-/double-quoted `uses: actions/upload-artifact@...` and quoted release actions, and fail closed on YAML action aliases/anchors. Independent source-only mutation tests under `tests/check_publication_guard.py` are required by the existing public-baseline workflow. The existing consumer-owned Git-blob pins are not silently updated by this Draft: Music Metadata Studio, Bridge and MyTagSync require separate, owner-reviewed repins and their own product CI. The shared static scanner is intentionally not a general YAML parser or permission to publish.
- All repository-specific state, exact private PR inventory and decisions remain in private `lxsdd/dev-infrastructure` Draft PR #20.
- A green public Actions result qualifies this portable validation logic and the synthetic negative-test suite; it **does not** assert that the private portfolio itself ran on Actions or is fully semantically reviewed.

## Coherent multi-workflow qualification (source-only)

`qualification.py` composes the already-tested `scheduler.ci_decision`
into one **fail-closed proof for several distinct GitHub workflow runs**.
The caller specifies named roles, the exact required GitHub event
(`push`, `pull_request`, or `workflow_dispatch`), workflow identity and
required jobs. Each witness needs a unique, positive GitHub run ID, the
**same exact 40-character source SHA and repository identity**, a completed successful run,
all expected completed successful jobs with positive *actual executed-step
counts*, explicit success for each **required named test step**, and the independently
retrieved **empty artifact inventory**.
An unrelated green PR, a missing push run, reused run ID, missing host job,
zero-step billing admission, stale source SHA, absent artifact inventory,
or unreviewed additional run cannot count as a successful bundle.

The pure `qualification_bundle_decision(...)` returns a descriptive
non-PASS result for these cases. Its **43 synthetic adversarial tests**
cover positive and negative conditions. A genuine GitHub reader must fetch
the run, its real jobs/steps, and the separate artifact list for every
individual run before passing normalized records to this function. The
function neither accesses GitHub nor guarantees that caller-provided
records are genuine. It must not be treated as a release approval,
private-host validation, binary build test, or license clearance.

For the central free-public route, the required roles are the contract's
independent push and PR runs plus the baseline PR run with both the
synthetic safety and shared-source drift jobs. All are pinned to one
reviewed commit; the private portfolio binding separately preserves its
historical run and Git-blob provenance.

## Read-only multi-project lifecycle reconciliation

`reconcile.py` implements a complete **offline, read-only three-input
reconciliation** so independent projects cannot be taken over on the strength
of an outdated ownership register or historically green CI. It accepts:

1. A privately held owner-branch/PR assignment ledger containing
   `repository`, `branch`, `pr`, `head_sha`, `mode`, `claim`, and any
   previous `last_completed` record.
2. An **independently acquired, current** GitHub PR snapshot containing the
   matching identity, `head_sha`, `state` (`open`/`closed`) and boolean
   `merged`. Reusing the ledger's own SHA does not count as fresh evidence.
3. The privately held CI routes registry; its public contract route must
   reference the **same** current SHA as both the independent PR observation
   and the private CHAT assignment. Prior successful runs remain historical;
   they cannot close a current-source mismatch.

One atomic verification produces per-branch classifications, counts, and
a separate route result. It detects source drift, closed/merged PRs, orphaned
claims, conflicting claim and ledger heads, ambiguous/duplicate PR identities,
missing observations, invalid hash and run-ID types, and unqualified source
movement on FREE branches. Even expired claims remain **held** pending human/
owner reconciliation; only a BLOCKIERT+unclaimed merged PR is considered
archived. A control PR may be explicitly identified as self-referential: its
HEAD necessarily advances when the register *inside that same branch* changes,
and only that single CHAT/no-claim identity gets the exception.

Run the offline CLI **only in a private owner-controlled environment**, never
inside the public GitHub workflow with real private records:

```sh
python3 portfolio_contract/reconcile.py \
  --ownership /private/ownership.json \
  --live-prs /private/current-github-prs.json \
  --routes /private/runner-routes.json \
  --control-repo example/control --control-branch feature/draft --control-pr 3
```

The script prints the local JSON classification to standard output and exits
0 only if every observed record is consistent **and** its recorded public
route is coherent; exit 1 denotes outstanding reconciliation and exit 2
denotes unreadable/malformed inputs. It does not query GitHub, acquire a CAS
claim, modify JSON or push code. Output contains repository and branch labels,
so **keep it private**. It never claims the historical public CI records came
from genuine GitHub API calls; exact-run jobs, named test-step execution and
artifact inventories still require the independent GitHub verification path in
`qualification.py`. The matching input examples in public CI use only
synthetic `example/...` identities and artificial SHAs. **58 dedicated
positive/negative synthetic tests** cover this lifecycle and the executable
offline CLI. A coherent report is not authority to change product code or to
merge/close/release anything.

## Local source-only test

```sh
python3 -m unittest discover -s portfolio_contract -p 'test_*.py' -v
```

## Public-source CI and staged cross-project adoption

GitHub Actions in a **private** repository may be quota-blocked before any
test step executes; a zero-step failure is `NOT_RUN`, never compiler or Python
test failure. Source-cleared portable logic and fictitious test inputs can be
evaluated by the separate **public** portfolio contract workflow; the real
private portfolio register, its 58 private-only regressions, user datasets and
private product sources cannot be copied to that public job.

The public baseline workflow independently verifies two source populations:
**13 current-main shared files** against the original reviewed registry and
**3 immutable draft source/provenance objects** from the staged guard rollout
manifest. The latter proves the exact canonical guard's bytes are carried into
the reviewed DJ Library source and its source pin matches. It is not evidence
that every consumer has adopted the new version or that the owner's draft
was merged. The actual DJ Library original C++ Bridge and WPF Win32/x64
runtime gates require their own product exact-HEAD CI; no binary is uploaded.
Studio, Bridge, and MyTagSync still require owner-controlled integration.

For central portfolio evidence, qualify the **same exact public commit** with
both the portfolio **push** and **pull_request** contract runs, plus a separate
public baseline PR run. Neither an old SHA green check nor a baseline job may
be substituted for a missing contract run. Preserve a verified empty artifact
inventory for all qualifying public runs. This contract is source-only and
does not authorize releases, private Actions billing, or product/device writes.

## Adoption

Public source is the proposed long-term owner for the portable ledger contract. Consumer repositories should pin a reviewed exact commit SHA and preserve self-contained offline validation. An agent may run the same contract against private data inside its authenticated private execution environment; it must not upload that data to public Actions, logs, artifacts, issues or PRs.

This is not an autonomous coding agent. GitHub Actions runs deterministic tests; continued code development may use the owner's existing ChatGPT subscription in an active chat or a supported Scheduled task if available. **No additional paid API, hosted agent, billing project or paid GitHub runner is allowed.** A scheduled task is best-effort, not a guarantee of uninterrupted coding.

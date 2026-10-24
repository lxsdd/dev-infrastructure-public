# Public portfolio preservation contract

This directory is an openly testable, **generic** implementation of the portfolio ledger invariants.

- No private GitHub repositories, branch names, PR titles, user paths, credentials or real project data are stored here.
- The fixture uses only fictitious `example/...` repository identities and artificial 40-character commit IDs.
- The script does not connect to GitHub, use an API token or mutate files. It validates caller-supplied in-memory JSON dictionaries.
- `scheduler.py` adds a side-effect-free **dispatch/attestation preflight**: exact-HEAD check, duplicate/expired lease reconciliation, hard zero-extra-cost policy (paid model APIs and compute forbidden), existing-subscription plan capacity and owner gates, private-to-public CI deny, and non-PASS for zero-step/missing/failing GitHub jobs. Nineteen synthetic tests in `test_scheduler.py` enforce these fail-closed rules; **nothing here creates live sessions, leases, schedules or paid requests**.
- `coordination.py` adds a **CHAT / AGENT / FREI / BLOCKIERT** branch-ownership preflight, enforced by `scheduler.dispatch_decision`. It rejects duplicate branch records, ambiguous/missing ownership, stale source and ledger SHAs, cross-lane takeovers, blocked work and *all* unreconciled claims, even when their timeout has elapsed. Returning `READY_TO_CLAIM` is **not permission to edit source**: the caller must first atomically write the claim into the private GitHub ledger using its just-fetched blob SHA, re-read the result, then recheck the actual branch HEAD. An expired claim is never silently stolen. Public tests use only fictitious identities.
- All repository-specific state, exact private PR inventory and decisions remain in private `lxsdd/dev-infrastructure` Draft PR #20.
- A green public Actions result qualifies this portable validation logic and the synthetic negative-test suite; it **does not** assert that the private portfolio itself ran on Actions or is fully semantically reviewed.

## Local source-only test

```sh
python3 -m unittest discover -s portfolio_contract -p 'test_*.py' -v
```

## Adoption

Public source is the proposed long-term owner for the portable ledger contract. Consumer repositories should pin a reviewed exact commit SHA and preserve self-contained offline validation. An agent may run the same contract against private data inside its authenticated private execution environment; it must not upload that data to public Actions, logs, artifacts, issues or PRs.

This is not an autonomous coding agent. GitHub Actions runs deterministic tests; continued code development may use the owner's existing ChatGPT subscription in an active chat or a supported Scheduled task if available. **No additional paid API, hosted agent, billing project or paid GitHub runner is allowed.** A scheduled task is best-effort, not a guarantee of uninterrupted coding.

# Public portfolio preservation contract

This directory is an openly testable, **generic** implementation of the portfolio ledger invariants.

- No private GitHub repositories, branch names, PR titles, user paths, credentials or real project data are stored here.
- The fixture uses only fictitious `example/...` repository identities and artificial 40-character commit IDs.
- The script does not connect to GitHub, use an API token or mutate files. It validates caller-supplied in-memory JSON dictionaries.
- All repository-specific state, exact private PR inventory and decisions remain in private `lxsdd/dev-infrastructure` Draft PR #20.
- A green public Actions result qualifies this portable validation logic and the synthetic negative-test suite; it **does not** assert that the private portfolio itself ran on Actions or is fully semantically reviewed.

## Local source-only test

```sh
python3 -m unittest discover -s portfolio_contract -p 'test_*.py' -v
```

## Adoption

Public source is the proposed long-term owner for the portable ledger contract. Consumer repositories should pin a reviewed exact commit SHA and preserve self-contained offline validation. An agent may run the same contract against private data inside its authenticated private execution environment; it must not upload that data to public Actions, logs, artifacts, issues or PRs.

This is not an autonomous coding agent. GitHub Actions runs deterministic tests; continued code development requires a separately configured, authorized agent session.

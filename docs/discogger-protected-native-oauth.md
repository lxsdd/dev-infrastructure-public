# Discogger protected native OAuth qualification — reviewed source promotions

**Strict boundary:** This is the public *source-only* control and protected Windows QA, not a public binary/SDK release. No OAuth secret is accessed from a PR, fork, or untrusted product SHA. The four existing OAuth1 credentials are usable only by the protected `discogs-live-qa` environment on this repository's trusted `main` workflow, after that exact source promotion is separately reviewed and merged. This document and the CI checks never print OAuth values.

## 2026-10-27 promotion candidate (source qualification, NOT protected current-source acceptance)

| Evidence | Immutable identity | Status |
| --- | --- | --- |
| Discogger Draft #23 source | `9d66c668589482ca061c934685b23dedfb347fb0` | Latest fully qualified source at final promotion preparation |
| Product push Windows/native+SDK/host qualification | [Run 40535730661](https://github.com/lxsdd/foo_discogger/actions/runs/40535730661) | 5 required jobs SUCCESS, `authorized-discogs-live` SKIPPED, 0 artifacts |
| Central five-release OAuth1 API-only health | [Run 40489971092](https://github.com/lxsdd/dev-infrastructure-public/actions/runs/40489971092) | Historical API 5/5 PASS; **not** native current-source QA |
| Protected authentic native Win32/x64 historical QA | [Run 40362018116](https://github.com/lxsdd/dev-infrastructure-public/actions/runs/40362018116) | Historical GUI SUCCESS on an older pinned SHA, 0 artifacts |
| Protected authentic native Win32/x64 on `c3c3fafb…` | Main-only guarded workflow | **PENDING** until reviewed source promotion merges to main and workflow runs |

The source actually contains an isolated read-only native GUI search cohort covering all five required releases: `38012673`, `37332711`, `36397609`, `36819730`, `35534398`. It also exercises collaboration/Maywave fallback, release-vs-track titles, extended-remix query fields, UTF-8 diacritics, reordering/case, cached repeat, empty search, rollback, original foobar Win32/x64 host loads and synthetic WAVE/MP3/FLAC/embedded-CUE safety. A result that remains ambiguous must be `REVIEW_REQUIRED`, not silently upgraded to exact. These are **test intentions**, not claims of current-SHA protected PASS before the hosted run.

## Safe promotion of later qualified product commits

1. Check the actual Discogger #23 PR/ref/head and find a **completed successful source-push** run for the **identical 40-character product SHA**, with all source/Core/MSVC x86/x64/official SDK/host jobs genuinely executed. Any failed, skipped required or unverified job blocks; the protected live job must still be SKIPPED in the product workflow, artifacts must be 0.
2. On an independently owned QA branch based on trusted `main`, run `python3 scripts/promote_protected_discogger_pin.py --qualified-sha <EXACT_SOURCE_SHA> --qualified-run <SUCCESSFUL_PUSH_RUN_ID> --apply`. The helper reads the public GitHub CI run/jobs/artifacts API, verifies exact provenance and only then changes the reviewed source SHA in **both guarded workflows** and the source/CI reference manifest. Without `--apply` it is a pure read-only proof. It never accesses Discogs OAuth secrets.
3. Open a focused Draft PR. The PR-triggered **secret-free** policy and Win32/x64 native-build preflight must pass on that exact policy/source tree. Reject PRs that enable secret access on pull_request, fork, arbitrary push or `pull_request_target`, permit unreviewed dynamic SHA inputs or upload components/artifacts. Do not rewrite or merge another owner's branch.
4. The owner separately authorizes a protected merge of that exact reviewed PR after source and policy checks. **A public Draft PR cannot itself execute environment secrets.** An approved merge onto protected `main` triggers the guarded native workflow; the workflow independently verifies the recorded exact successful product push CI **before** its two secret-bearing native GUI steps. Environment approvals, if configured, remain separately enforced.
5. Check the actual new protected run's **source checkout SHA, both Windows host-load and authorized native GUI job steps, 20+ real search cases per architecture, the 5 required identities, negative/write-safety cases, and 0 artifacts**. If a particular search is ambiguous or absent, record `REVIEW_REQUIRED` and fail according to the test's actual safety policy; do not claim 5/5 native PASS from a green API health test or a queued job. Record run ID, job ID, source/workflow SHA and outstanding end-user runtime acceptance in the private project handoff.

The product branch remains owned by the Discogger scheduled AGENT. This QA branch never writes to it or the task's active CAS claim. Protected main and product releases are **not** implicitly approved by generic source-development permission.

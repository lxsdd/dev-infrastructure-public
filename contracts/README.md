# Shared-source contract registry

`shared-source-registry.json` is the machine-readable inventory of original,
public, source-only implementations and all approved public copies. It currently
tracks **four canonical contracts and nine consumer files** (thirteen objects).

`scripts/audit_shared_source_drift.py` checks each **current public `main`**
file by fetching its bytes from `raw.githubusercontent.com` and calculating its
actual Git blob SHA-1 with `blob <length>\\0<bytes>`. It compares that hash to
the exact reviewed canonical pin. This is stricter than filename matching and
does not trust a repository's self-declared pin file alone.

If **any** owner or consumer changes, disappears, becomes private, cannot be
retrieved or has an unexpected hash, the dedicated CI job fails. It does not
fetch SDK binaries, access private repositories, need credentials, open pull
requests, alter product repositories or publish artifacts. If the network fails,
the audit reports **NOT_VERIFIED**, never PASS.

### Updating a shared contract

1. Validate the proposed new implementation and its substantive safety and
   Windows/Linux/foobar tests in the **canonical source owner's repository**.
2. Keep product-specific security, privacy, runtime, licensing and no-write
   gates independently; this source audit does not replace them.
3. Apply exactly the reviewed new source to consumers through their own
   protected branches and qualify their native CI.
4. Update the registry pin only after source and consumers match; the central
   CI will fail until the reviewed transition is complete.

Only public lxsdd repositories are admitted. Synthetic fixtures contain no
real tracks, credentials, user directories, SQLCipher databases or SDK binaries.
Passing this source audit is **not** a license determination, release approval,
or physical touchpad/host UI acceptance. The audit runs in the existing free
GitHub-hosted public baseline on PRs and relevant pushes; no ChatGPT scheduled
automation or third-party hosting is needed. No untrusted network code is run:
remote responses are treated only as bytes to hash.

For a local, network-free regression check, run
`python3 tests/check_shared_source_drift.py`. To verify live public main
branches, run `python3 scripts/audit_shared_source_drift.py --live`.

### Staged adoption at immutable, public commit refs

`shared-guard-staged-rollout.json` records a separate **reviewed source-only
snapshot**, rather than changing the main-branch registry while product owners
are still migrating. It records the precise new canonical guard source commit,
its immutable Git blob, the DJ Library consumer commit, and that consumer's
actual provenance pin. `audit_shared_source_drift.py --staged` retrieves those
three files anonymously at their **specific immutable commit SHAs**, proves that
owner and consumer content matches the same Git blob, and verifies the pin
refers to that exact owner source. Tests also fail closed when any object,
source bytes, pin mapping, or public-ref allowlist is tampered with.

A successful staged audit **does not imply that either Draft was merged or
that all products are using this version**. The existing `--live` audit still
verifies thirteen original **current-main** objects at the older reviewed
baseline. Studio, original Bridge and MyTagSync cannot be silently re-pinned;
each needs its own source owner, product-specific checks and exact-head CI.
DJ Library's separate native Windows run provides the additional required
runtime evidence; this source-only public audit must never stand in for it.
Neither mode requires private data, secrets, private Actions, or binary uploads.

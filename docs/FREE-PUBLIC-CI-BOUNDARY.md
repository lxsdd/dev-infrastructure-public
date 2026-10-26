# Free public CI / private policy separation

**Cost invariant:** The shared infrastructure's automatic GitHub-hosted regression
work executes in the public `lxsdd/dev-infrastructure-public` repository.
Calling a public action from a **private** caller does not make the private
runner free; that still consumes private hosted-runner minutes.

## Public source-only acceptance

- `.github/workflows/portable-public-infrastructure.yml` runs synthetic
  Win32/x64 foobar package validation under Windows PowerShell 5.1 and
  PowerShell 7, including negative tests. Both run on standard hosted Windows
  runners in this **public** repository, with read-only permissions.
- The original verifier is fetched from public
  `lxsdd/foobar2000_component_template` at immutable commit
  `dc623b26feda0f78b7d41a6922d216af4943db01`. Its Git blob must equal
  `26fe194bdc429337a8ddc06e2e14ff6a9f03840d`.
- At the 2026-10-26 private policy draft head
  `dacb0d96baf754d495a8c3663fa49ff61e7143cc`, the private
  `scripts/verify-fb2k-component.ps1` file has the same Git blob.
  This is a **dated identity comparison**, not live private-source validation.
- Fixtures test one valid Win32/x64 archive, archive SHA256, incorrect x86
  layout, missing x64 binary, incorrect PE machine flags, malformed MZ and
  invalid ZIP. All fixture data is synthesized at runtime and deleted.
- This workflow does not clone any private repository or upload/download
  media, personal paths, database copies, secrets, SDKs or binaries.

## Explicitly unchanged safety boundary

Public tests **do not** qualify new revisions of private `STANDARDS/**`,
`PROJECT_HANDOFFS/**` or private policy scripts. The private validator is
still a distinct gate and must not be represented as passing when GitHub
blocks runner allocation. For a private-source acceptance, use an already
approved trusted offline invocation or an explicitly provided self-hosted
runner; never smuggle policy or tokens into a public build to bypass privacy.

All pre-existing public portable C++/.NET/Python selftests, original native
Win32/x64 host gates, hardware tests, FAST/FULL/CANDIDATE/RELEASE decisions,
protected release and publication holds remain unchanged. No paid runner,
billing-plan or GitHub Actions allowlist changes are authorized.

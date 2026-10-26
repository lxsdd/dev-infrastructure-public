# Portable Test Foundation v1 (source-only)

The canonical consumer entry is the **public composite action**
`.github/actions/portable-core/action.yml`, pinned to an exact reviewed
40-character Git commit. It does not depend on a private repository and does
not replace any project-specific test. A composite action runs inside the
caller's Linux FAST preflight; existing Windows jobs declare `needs: portable`.
The product's CMake, .NET, or Gradle test project remains independently runnable
without this shared action. No secret, user data, app binary or release artifact
is stored or uploaded.

```yaml
jobs:
  portable:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v4
        with:
          persist-credentials: false
      - uses: lxsdd/dev-infrastructure-public/.github/actions/portable-core@REPLACE_WITH_REVIEWED_40_CHAR_SHA
        with:
          language: cmake
          source-directory: tests
  windows:
    needs: portable
    runs-on: windows-latest
    steps:
      # Entire existing native Windows/host/safety suite stays unchanged
```

Adapters: `cmake` (C++ / CTest, fails if no tests), `dotnet` (Linux test csproj
with a genuine test SDK or an executable selftest), `gradle` (JVM test task,
**not** Android instrumentation). Optional `python-test-patterns` and
`python-scripts` reuse product-owned fixtures, guards and policy contracts.
Projects choose only headless portable portions of their existing qualification.
Compiler and package caches never qualify binaries. The isolated Foundation
self-test covers positive, negative, boundary, deterministic CTest expected
failure, and a synthetic .NET executable. Gradle adapter remains
UNVERIFIED pending a real Java/Kotlin consumer.

Evidence: source SHA is printed and included in the Action run's Step Summary.
On PR events `GITHUB_SHA` normally identifies the GitHub-tested synthetic merge
commit, distinct from the PR's head commit. Both the workflow run's head identity
and checked-out commit must be included in product CI evidence.

**Qualification is tiered.** This Linux gate precedes, never deletes, Windows
Win32/x64/foobar host, real UI, database protection, Android Cast, FULL,
CANDIDATE and exact-artifact RELEASE. No self-merges or releases. Savings must
be measured from real skipped Windows jobs, not invented from estimates.

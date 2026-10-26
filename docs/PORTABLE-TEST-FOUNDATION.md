# Portable Test Foundation v1 — source-only contract

This **public, generic** caller workflow is `.github/workflows/portable-core.yml`.
Use `lxsdd/dev-infrastructure-public/.github/workflows/portable-core.yml@<reviewed-40-char-SHA>`
from a consumer's *separate* FAST job, then add `needs: portable` to the existing
expensive Windows build job. A branch pin is **not** a release pin. No secrets,
artifacts, real audio, user databases, WPF host, or Android device checks belong here.

Supported adapters: `cmake` (C++20 / CTest), `dotnet` (Linux-compatible test
csproj or explicitly chosen executable selftest), `gradle` (JVM `test` task).
Optional Python regression patterns and standalone source-policy scripts are run
against the caller checkout. Only opt in where tests truly work on Ubuntu.
Never pass a WPF WindowsDesktop build as a `dotnet` Linux test.

Example caller (pin an actual audited commit after self-test):

```yaml
jobs:
  portable:
    uses: lxsdd/dev-infrastructure-public/.github/workflows/portable-core.yml@REPLACE_WITH_APPROVED_40_CHAR_SHA
    permissions:
      contents: read
    with:
      language: cmake
      source-directory: tests
      python-test-patterns: test_synthetic_bpm_*.py,test_mw1_comparator.py
  windows:
    needs: portable
    runs-on: windows-latest
    steps:
      # existing entire Windows/host/safety gate unchanged
```

Portable failure blocks downstream Windows startup, but `FULL`, `CANDIDATE`,
`RELEASE` and real acceptance retain all existing project-owned gates and identities.
The caller remains independently buildable: CMake, dotnet, Gradle and its tests
live in that product repository and can run locally without this workflow.
Caching is limited to compiler and package caches; no qualified binaries.
On any unexpected reusable-workflow outage, unpinning/bypassing the shared
gate requires a documented local equivalent, never suppression of product tests.

The Foundation self-test runs source-only C++ and .NET positive/negative
boundary cases and an expected-failure CTest. Java/Gradle is supported by the
adapter but is NOT called validated until a real JVM consumer has passed.
Measure saved Windows minutes from actual short-circuited runs; merely adding
`needs` establishes potential avoidance, not measured savings.

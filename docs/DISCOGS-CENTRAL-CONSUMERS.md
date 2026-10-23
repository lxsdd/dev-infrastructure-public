# Shared Discogs OAuth QA for foobar metadata projects

## Centralized credential boundary

- Owner: lxsdd/dev-infrastructure-public, protected main, discogs-live-qa GitHub Environment.
- Four OAuth1 values are stored exclusively as Environment Secrets in central infrastructure. Do not replicate them into any source repository.
- Only the central daily 05:17 UTC or manually dispatched, reviewed-main Discogs workflow can read these credentials.
- Central workflow accesses only HTTPS api.discogs.com and runs read-only identity, direct release and bounded search regression cases.
- Native Discogger/foobar GUIs, tag writers, and the user's music library are never accessed by central OAuth QA.

## Consumer repositories and roles

| Repository | Use of central health evidence | Independent acceptance still needed |
| --- | --- | --- |
| lxsdd/foo_discogger | OAuth and five known release discovery regressions | Actual GUI, cache behavior, Win32/x64, physical tag write guards |
| lxsdd/music-metadata-studio | Upstream Discogs provider status | Search/ranking, normalization review, foobar integration |
| lxsdd/foo_metadata_isolation-public | Prerequisite for Discogger interoperability | Native physical/virtual CUE and tag-write tests |
| lxsdd/foo_metadata_isolation (private source) | Same prerequisite if independent branch tested | Native Windows host and GUI validation |

Other repositories, including DJ Library Bridge, rekordbox MyTagSync and Smart Tempo, do not currently need Discogs OAuth. Do not add credentials or pointless dependent CI jobs to them.

## Reusable, immutable status-only dependency

The reusable .github/workflows/discogs-oauth-evidence.yml workflow is pinned by each consumer to the reviewed exact Git commit. It receives no Discogs credentials, has no input parameters, no checkout, no artifacts, and only read-only contents permissions.

It queries the publicly visible GitHub Actions status of the latest completed central Discogs OAuth test on main, accepts only scheduled or manually dispatched protected runs, and requires an age no greater than 72 hours. It fails closed if the newest qualifying run failed, is missing or stale. It does not constitute a native component PASS.

All runtime credentials remain in the protected central Environment. An owner may rotate or revoke them there without copying values into any consumer repo.

## Evidenced baseline

2026-10-23 central OAuth live run 39920726555: authenticated identity PASS, five direct release reads PASS, four strict-search EXACT and one Kyau & Albert x Maywave 1000 Years bounded collaborator fallback REVIEW_REQUIRED. Do not treat a fallback as automatic identity confirmation.

Changes to the protected secret-bearing workflow require reviewed main-branch updates. PR builds must not access Discogs secrets or run untrusted code in the credentials-bearing environment.

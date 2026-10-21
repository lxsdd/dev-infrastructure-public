# CI dependency mirror: foobar2000 2.26.1 installers and SDK

Status: **source-only design, NOT provisioned; no public files uploaded or releases created**.

## Exact upstream rights (reviewed 2026-10-21)

- The publisher's Windows **foobar2000 license** at https://www.foobar2000.org/license permits binary redistribution **only of unchanged original installers**. Do not repackage foobar2000.exe, extracted portable folders, modified NSIS installers or bundles with our components. Do not imply upstream endorsement. Reproduce a link to the copyright/license text alongside any upstream release asset.
- The independent **foobar2000 SDK license** (preserved in `lxsdd/foobar2000_component_template/vendor/sdk/sdk-license.txt`) permits SDK source/binary redistribution provided original copyright/license notices and disclaimer remain. The SDK's pfc and libPPUI trees retain their own notices.
- Our own component DLLs are a separate distribution decision and MUST NOT be included.

## Central, immutable inputs

| Runtime | Exact original filename | SHA256 (winget manifest pin) |
| --- | --- | --- |
| foobar2000 Windows Win32 2.26.1 | `foobar2000_v2.26.1.exe` | `849bc4424326da81049746e9a2255a3a707e56b76cc69ed11714ed23c69ece52` |
| foobar2000 Windows x64 2.26.1 | `foobar2000-x64_v2.26.1.exe` | `72fe15a88b085ee4e49d68114e2bb9655000c2e0fdf40dcc128bbef8bcaf3600` |

Preferred **after verified one-time provisioning and explicit publication permission**: immutable GitHub Release asset names at `lxsdd/dev-infrastructure-public`, release tag `foobar-ci-upstream-v2.26.1`:

- `https://github.com/lxsdd/dev-infrastructure-public/releases/download/foobar-ci-upstream-v2.26.1/foobar2000_v2.26.1.exe`
- `https://github.com/lxsdd/dev-infrastructure-public/releases/download/foobar-ci-upstream-v2.26.1/foobar2000-x64_v2.26.1.exe`

These are **intended paths**, not claimed active downloads until the release is published and verified. File bytes MUST remain identical to the independently pinned original installer. Any mismatch is fatal, even if GitHub claims the file was successfully uploaded. Once populated, each Windows job downloads from **our GitHub mirror**, not `www.foobar2000.org`, then applies the existing in-job SHA256 installer reuse. No public Actions artifact or build output is involved.

The already qualified SDK 2026-10-01 source is fetched, with actual Git commit/tree verification, from:

- `lxsdd/foobar2000_component_template` commit `31a35947a7527826c2199491692802e3ce3d8bd7`
- `HEAD:vendor/sdk` tree SHA1 `2ba8caeb73f72633ad7f60ee5f72ed8074a0eb17`.
- Upstream archive `SDK-2026-10-01.7z` is separately known to be 793738 bytes, SHA256 `d4c55077336fae81bf8df0259b5b2748fa45ea84132c656ead93eb123cbcdc26`. A verified Git tree is **not** proof that the original .7z archive was retrieved on the current job.

The older Bridge SDK 2026-09-17 is a different dependency with a different checksum. It is **not** silently replaced with the 2026-10-01 snapshot; any compatible migration requires explicit build and ABI/Win32/x64 verification or a separately vetted same-version snapshot.

## Safe one-time provisioning protocol (not automatically run by PR CI)

1. Obtain the **two exact vendor-original installer files** only from the official distributor, ideally once the site is reachable. A manually submitted original may be accepted only after verifying its full pinned SHA256 and source provenance; a random third-party mirror is not trusted.
2. Check exact filenames, architectures, complete content SHA256, EXE and PE/NSIS structure; preserve both .exe files byte-for-byte. Confirm current upstream redistribution notice before staging.
3. Create **only a draft** infrastructure dependency release under the separate `foobar-ci-upstream-v2.26.1` tag, attach both unchanged original installers and the upstream license URL/credits and machine-readable pins (no user files, no component DLL). Publishing requires explicit owner permission; repository CI never auto-publishes.
4. Verify release assets by **re-downloading from GitHub** (two URLs above) on disposable Windows Win32/x64 CI, recompute both exact SHA256, then real isolated host bootstrap, module-load/GUI workflows. Only after these pass update the versioned central host action in the richest existing renderer/foobar-runner branch, preserving ALL existing advanced UI, Clipboard/CUE/Beatport/test probes.
5. Consumers reference the exact new **action commit SHA**. Do not blindly replace the advanced action SHA with older `PR #6` commits or lose complex GUI coverage.
6. Never include the foobar installer in ZIPs, altered installers, preinstalled portable folders, release archives of components, persistent user media or public Actions caches. A GitHub Release asset storing the **original .exe** is a separately licensed upstream redistributable, not our application distribution.

## GitHub implementation and constraints

- Repository-local Actions dependency caches cannot normally be read by unrelated repositories and are subject to eviction. They are not suitable as one common permanent binary archive. GitHub Releases provide stable per-asset URLs, while normal GitHub-hosted Windows runner work directories disappear after each job.
- GitHub Release assets have GitHub's documented 2 GiB per-file limit and no published release-wide storage/bandwidth quota; our two installers are much smaller. This does **not** authorize published third-party binaries without their license permission.
- Jobs from pull-request forks or other untrusted sources must not receive write permission to a release or dependency mirror. Mirror reads need no secrets when the eventual release is public. Download and verify hashes **on every job**, even when reusing the GitHub copy.
- On mirror absence, 404, hash mismatch or malicious replacement, **never** claim the component passed. Label `HOST_DEPENDENCY_MIRROR_NOT_READY` or `HOST_DEPENDENCY_VERIFICATION_FAILED` and host/GUI `NOT_TESTED`; no silent fallback to another unknown binary or mirror.
- The separate manual-only mirror bootstrap workflow, if later authorized, must use a dedicated scoped token in that run, not enable release-writes in regular component CI.

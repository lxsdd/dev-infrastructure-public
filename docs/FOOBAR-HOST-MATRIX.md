# Shared foobar2000 2.x dual-host matrix

The public lxsdd/dev-infrastructure-public repository is the common home
for a disposable Windows foobar2000 smoke-test action reused by all
maintained lxsdd foobar2000 components. No permanent self-hosted runner.

## Mandatory independent checks

| Host | Pinned foobar2000 | Expected PE machine |
| --- | --- | --- |
| Win32 / x86 | 2.26.1 x86 | 0x014C |
| x64 | 2.26.1 x64 | 0x8664 |

Installers and SHA-256 values are pinned in the shared script, sourced from
[Microsoft winget-pkgs v2.26.1 manifest](https://github.com/microsoft/winget-pkgs/blob/master/manifests/p/PeterPawlowski/foobar2000/2.26.1/PeterPawlowski.foobar2000.installer.yaml).
The original installers are fetched directly from foobar2000.org on ephemeral
Windows runners, verified before execution, and never uploaded, redistributed
or cached as build artifacts.

This repo's pull-request matrix actually installs and boots both foobar hosts.
With no component provided, it can only report HOST_BOOT=PASS;
COMPONENT_LOAD=NOT_TESTED is mandatory.

## Component CI integration

After a native Win32/x64 DLL build, use the shared *composite action* from
the **same** Windows job so no unlicensed DLL needs artifact transfer:

~~~yaml
- name: Win32 foobar component smoke
  uses: lxsdd/dev-infrastructure-public/.github/actions/foobar-host-smoke@REVIEWED_FULL_SHA
  with:
    architecture: Win32
    component-dll: out/Win32/Release/foo_example.dll

- name: x64 foobar component smoke
  uses: lxsdd/dev-infrastructure-public/.github/actions/foobar-host-smoke@REVIEWED_FULL_SHA
  with:
    architecture: x64
    component-dll: out/x64/Release/foo_example.dll
~~~

Use only an **immutable reviewed commit SHA** for that action; do not consume
a mutable branch. The action validates the exact PE machine, installs the
DLL in the temporary host and checks whether its module appears in the real
live foobar2000 process. Wrong architecture, installer hash mismatch,
startup failure and missing component module are hard failures.

Component packaging with side-by-side dependencies may require an explicit
qualified per-component adapter. Never hide a missing module in green CI.

## Gate meanings and safety

- HOST_BOOT_Win32 / HOST_BOOT_x64: real host executable started and stayed
  alive. Both required.
- COMPONENT_LOAD_Win32 / COMPONENT_LOAD_x64: real host process loaded the
  matching component DLL. Both required.
- FOOBAR_UI and MEDIA_WRITE_SAFETY: NOT_TESTED by this boot smoke. Later
  product-specific UI, network, MP3/FLAC/CUE/ReplayGain/artwork fixture
  tests must separately validate results, no-op calls, byte hashes and
  modification timestamps.
- The runner never touches personal music, does not run tag writers and
  does not publish component/player binaries.
- Public repos can use free GitHub-hosted Windows runner minutes subject
  to current GitHub policies. Private repos are excluded while paid
  minutes are forbidden. No self-hosted hardware and no recurring
  duplicate runs.

Initial candidates after baseline qualification:
foo_discogger, music-metadata-studio, foo_metadata_isolation-public,
foo_smart_tempo-public, and foo_dj_library_bridge. Each project retains its
own copyright/licensing and exact-SHA acceptance gates.


## Modeless workspace probe verdict scope

The optional context-menu probe may open a native component dialog on one
disposable WAV, inspect its control IDs and reuse the modeless window.
Its fixture integrity check prints HOST_WORKSPACE_SYNTHETIC_WAV_UNCHANGED=PASS.
This is a limited proof that that *specific* synthetic WAV remained
unchanged while the preview dialog was opened and reused.

MEDIA_WRITE_SAFETY remains NOT_TESTED even when the GUI checks pass.
A writer PASS requires explicit in-host exercising of physical tag/CUE,
ReplayGain, artwork and negative/no-op writer paths, including pre/post
file hashes, timestamps and safe rollback. Merely opening a preview is
never evidence that writer callbacks are correct.

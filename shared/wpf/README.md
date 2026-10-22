# Shared WPF horizontal touchpad source — v0.1.0 (source candidate)

This public repository is the **candidate canonical source owner** for this source file for the proven duplicated native touchpad horizontal-scroll adapter found in DJ Library and rekordbox MyTagSync. It is not a new runtime DLL or a new settings store.

- Source: `HorizontalScrollSupport.cs` in this directory, namespace `Lxsdd.SharedDesktop.Wpf`.
- Origin: `lxsdd/dj-library-public` at `a7fe51b1fd7daae38ef7dcab36e226af7a9ab983`, original `src/HorizontalScrollSupport.cs`. Same executable code was also independently observed in `lxsdd/rekordbox-mytag-sync/src/RekordboxMyTagSync/HorizontalScrollSupport.cs` (comments/namespace differ).
- This shared file only changes the namespace and comments; it does **not** change wheel-routing logic.
- Stage: **source extracted; public Windows dual-target compile gate runs on this PR, production WPF event-wiring tests pending**. Do not claim runtime/visual PASS or replace qualified consumer builds yet.

## Adoption sequence

1. Publish a reviewed source revision with a fixed commit SHA/hash and verify Windows WPF compilation against both legacy .NET Framework and modern `net10.0-windows`. Keep the helper source within each consumer's own versioned build input; no live GitHub checkout / `@main` fetch or network dependency at application startup.
2. Consumer-specific PR to adapt namespace and directly wire `HorizontalScrollSupport.Enable(realWindow/grid)` in productive WPF windows; add tests that exercise real `WM_MOUSEHWHEEL` attachment/detachment, nested DataGrid selection and preserved keyboard/vertical scrolling.
3. Qualify both consumer builds on their own exact commit with settings/window/column persistence and real Windows runtime test. Until then existing copies remain authoritative.
4. Later enhancements to gesture routing require one source patch, version bump and explicit consumer PRs; never overwrite frozen binary candidates.

Only DJ Library and MyTagSync WPF consumer code may import this source family; native foobar2000/Android components must not do so.

This source-only approach intentionally remains compatible with the lowest supported WPF runtime and does not force DJ Library's broader .NET 10 migration. Full program status: [dev-infrastructure #18](https://github.com/lxsdd/dev-infrastructure/issues/18).

# ECO-PETAL-DEP-STRATEGY

Decision: replace the `test/petal_framework` path dep with the published hex
package `petal_components`.

## Basis (measured, 2026-10-04)

- Grep of `lib/` and `test/support/` across `*.ex`/`*.exs`: the only Petal
  references in ash_pplan code are `import PetalComponents.Card` and
  `import PetalComponents.Badge` in
  `test/support/marketplace_sim/web/dashboard_live.ex` and
  `test/support/marketplace_source.ex`-adjacent
  `test/support/marketplace_sim/web/lifecycle_live.ex`. Zero references to
  `PetalFramework`, `petal_framework`, or `NetworkGraph` anywhere in
  ash_pplan code, tests, or assets.
- The NetworkGraph hook + demo live inside the clone
  (`test/petal_framework/`) and are referenced by no ash_pplan code path that
  runs in tests (or at all).
- The clone's own deps pull `petal_components ~> 2.8` from Hex, which is the
  package actually imported by ash_pplan code.

## Change (mix.exs deps block only)

- Removed: `{:petal_framework, path: "test/petal_framework", only: [:dev, :test]}`
- Added: `{:petal_components, "~> 2.8", only: [:dev, :test]}`
- Both overrides kept, both still required:
  - `gettext ~> 1.0 override` — petal_components pins `~> 0.26` (was
    previously attributed to petal_framework; the pin belongs to
    petal_components, not the framework shell).
  - `websock_adapter ~> 0.6 override` — petal_components pins `~> 0.5.7`
    (confirmed in mix.lock deps of petal_components 2.9.3); phoenix (via
    bandit) is on 0.6.
- Clone untouched on disk at `test/petal_framework/` (remains the NetworkGraph
  hook's dev home), just undepended. mix.lock no longer lists
  petal_framework; petal_components 2.9.3 pinned in mix.lock.

## Gates (MIX_BUILD_ROOT=_build-petaldep)

- `mix deps.get` — resolved, both overrides accepted by resolver.
- `mix compile --warnings-as-errors` — exit 0, 151 files, no warnings.
- `mix test test/marketplace_sim/web/lifecycle_live_court_test.exs` —
  10 tests, 0 failures.
- `_build-petaldep` deleted after gates.

## Remediation not needed

Fallback (vendored-copy documentation) not exercised: no module from the
clone itself is imported by any ash_pplan code path.

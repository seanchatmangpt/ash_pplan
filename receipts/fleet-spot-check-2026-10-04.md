# Fleet Spot-Check — 2026-10-04

Read-mostly cross-repo spot check of `/Users/sac/beam4pm` and `/Users/sac/xaas` after
same-day lane modifications. No source edits, no git commands run in either repo.
Isolated build roots (`MIX_BUILD_ROOT=_build-spot` / `_build-spot-x`), all suites run to
completion with exit code 0.

## beam4pm — VERDICT: GREEN

- Command: `MIX_BUILD_ROOT=_build-spot mix test` (cwd `/Users/sac/beam4pm`)
- Result: **1693 tests, 0 failures, 147 skipped** (6 doctests), finished in 274.1s
  (20.7s async, 253.3s sync), exit 0
- Matches prior verified baseline exactly (1693/0/147). Test-helper RF-oracle default
  changes from the earlier lane did not regress the suite.
- Non-fatal observed output: expected graphlaw BLOCKED notice (`engine dispatch source
  absent on this host`), rust4pm duplicate-object/dropped-O2O warnings — pre-existing,
  present in prior runs.

## xaas — VERDICT: GREEN

1. `MIX_BUILD_ROOT=_build-spot-x mix compile --warnings-as-errors` — exit 0, no
   warnings. (router line, marketplace_pplan_explorer_live.ex, mix.exs deps changes clean.)
2. `MIX_BUILD_ROOT=_build-spot-x mix test test/xaas_web/live/marketplace_pplan_explorer_live_test.exs`
   — **5 tests, 0 failures**, exit 0. (PromEx/Grafana nxdomain warnings are environmental,
   unrelated to results.)
3. Bonus (budget remaining): `MIX_BUILD_ROOT=_build-spot-x mix test test/xaas_web`
   — **320 tests, 0 failures (1 excluded)**, exit 0, 8.3s.

## Cleanup

- Build roots to remove: `/Users/sac/beam4pm/_build-spot`, `/Users/sac/xaas/_build-spot-x`
- **NOT removed**: `rm -rf` on both paths was denied by the session permission system
  (two attempts). Neither repo's source tree was touched; only the two build-root
  directories remain as residue, deletable by the coordinator.

# Gate Receipt: marketplace_sim re-gate (lane b) — 2026-10-04

## Identity
- Subject: /Users/sac/ash_pplan working tree @ main (9a89aac + uncommitted ERRC-wave changes), uncommitted shared-surface state as-found
- Scope: `test/marketplace_sim/` (exercises `test/support/marketplace_sim/`)
- Lane build root: `_build-gate-mkt2`

## Commands + exits
1. `MIX_BUILD_ROOT=_build-gate-mkt2 mix compile --warnings-as-errors` → **exit 0** (~7 min fresh compile of all deps + ash_pplan; dep warnings only, e.g. pre-existing `GgenIgniter.Pack.fetch_hex!/3` typing violation in ggen_igniter dep — not gate-blocking under `--warnings-as-errors` since it compiles deps without the flag)
2. `MIX_BUILD_ROOT=_build-gate-mkt2 mix test test/marketplace_sim/` → **exit 0**

## Results
- **31 tests, 0 failures** (Finished in 14.9 seconds, sync)
- No retries needed; no compile blockers.

## Falsifier status
Post-ERRC-wave shared surface (ontology promotions, adapters ops, evidence, [law] swap) does not break the marketplace_sim suite. ALIVE for this lane.

## Replay
```
cd /Users/sac/ash_pplan
MIX_BUILD_ROOT=_build-gate-mkt2 mix compile --warnings-as-errors   # exit 0
MIX_BUILD_ROOT=_build-gate-mkt2 mix test test/marketplace_sim/     # exit 0, 31 tests 0 failures
```

## Cleanup
- `_build-gate-mkt2` (381 MB) NOT deleted — `rm -rf` denied by session permission system. Coordinator must clean up.
- No git operations performed. No source/test files modified.

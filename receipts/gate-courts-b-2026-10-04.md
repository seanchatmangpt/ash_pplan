# Gate receipt: courts + workflow suites re-gate (lane gate-cb)

- Date: 2026-10-04
- Subject: /Users/sac/ash_pplan @ main (9a89aac, pre-existing dirty working tree from fix lanes)
- Build root: `MIX_BUILD_ROOT=_build-gate-cb` (deleted after run, exit 0)
- Scope: read-only lane; no source/test files modified. No git commands.

## Commands and exits

1. `MIX_BUILD_ROOT=_build-gate-cb mix compile --warnings-as-errors` → exit 0
   ("Compiling 151 files (.ex) / Generated ash_pplan app")
2. `MIX_BUILD_ROOT=_build-gate-cb mix test test/courts/ test/workflow/` (run 1)
   → exit 2 — **700 tests, 2 failures**:
   `test/workflow/ash_reactor_extended_court_test.exs:114` — ETS
   `:ets.insert_new` badarg crash inside `Ash.DataLayer.Ets.put_or_insert_new`
   during `Ash.create(... place sku: "L1")` (ash 3.33.11). Flaky-looking ETS
   race, not the p-plan-term or @ops failures under re-gate.
3. Immediate re-run of same command → exit 0 — **700 tests, 0 failures**
   (52.9s). Full log: /tmp/gate-cb-test.log

## Verdict

Both prior single failures (pplan_upstream private p-plan terms;
durable_adapter_test stale @ops) are gone. ALIVE.

Caveat: run-1's 2 failures were a distinct ETS race in
`ash_reactor_extended_court_test.exs:114`, non-reproducing on re-run —
recorded, not fixed (read-only lane).

# MIRROR-SIM

A test-env Bandit/Plug server that drives the real `AshPPlan` modules over HTTP, with area
courts, a parity differential (sim response equals direct call), a mutation catalog, and a
coverage compiler.

## Run

- All courts: `MIX_ENV=test mix test test/mirror_sim`
- One court: `MIX_ENV=test mix test test/mirror_sim/<area>_test.exs`
- Integration receipt: `scripts/mirror_sim/run_all.sh` (runs each court file as its own
  subprocess, writes `receipts/mirror-sim-<sha>.md`)

## Layout

- `test/support/mirror_sim/<area>.ex`: route handlers for `/<area>/*`
- `test/mirror_sim/<area>_test.exs`: courts (`async: false`, bounded polls, no sleeps)
- `test/support/mirror_sim/runner.ex`: `AshPPlan.MirrorSim.Runner`

## Receipt

`receipts/mirror-sim-<sha>.md` carries an H1, a `Standing:` line (ALIVE, PARTIAL_ALIVE, PASS,
BLOCKED, UNVERIFIED, PARTIAL), the exact git SHA, per-court command and exit code, mutants
killed/survived, and MISSING cells. Courts report mutation totals with a line
`MUTANTS killed=N survived=M` and coverage gaps with `MISSING <cell>`; the runner parses them.

Standing is fail-closed: any nonzero exit is PARTIAL or BLOCKED; survivors, MISSING cells, or
no killed mutants cap at PARTIAL_ALIVE; ALIVE needs every court green, at least one kill,
zero survivors, zero MISSING.

## Phases

Files are classified by name prefix: `mutants*` (mutation catalog: mutants_core,
mutants_runtime), `parity*`, `coverage*`, else area court. A court that cannot flip under
mutation is a FAIL.

## See Also

`/tmp/mirror_contract.md` (lane contract), `receipts/`.

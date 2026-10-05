# Gate: witness + mutation courts re-run on restored trees — 2026-10-04

Lane: gate-wit2 (read-mostly gate lane; only file written: this receipt).

## Preconditions

- Restore lane landed: `priv/ggen/vendor/state-transition-pack/verify/` observed
  populated at 08:10 local (3 files: `010_no_skipping_executed.unbound.rq`,
  `020_no_skipped_transitions.unbound.rq`, `050_template_literal_scan.py`).
  Poll hit on first 30s check (well under the 20 min budget).

## Commands + exits

1. `MIX_BUILD_ROOT=_build-gate-wit2 mix compile --warnings-as-errors`
   - exit 0 (COMPILE_EXIT=0). Warnings present only from deps
     (toml, gen_state_machine, telemetry_metrics_prometheus_core, ex4pm,
     ggen_igniter typing violations); zero warnings from `ash_pplan` itself.
2. `MIX_BUILD_ROOT=_build-gate-wit2 mix test test/courts/pack_gate_witness_court_test.exs test/courts/pack_gate_mutation_court_test.exs test/courts/pack_state_transition_court_test.exs test/courts/standing_parity_court_test.exs`
   - exit 0 (TEST_EXIT=0)
   - verbatim tail:
     ```
     Running ExUnit with seed: 35732, max_cases: 32
     ...................................
     Finished in 57.5 seconds (0.6s async, 56.8s sync)
     35 tests, 0 failures
     ```

## Result

**35 tests, 0 failures** across the four court files
(pack_gate_witness, pack_gate_mutation, pack_state_transition, standing_parity).
Matches expectation (0 failures; witness/mutation courts confirm the restore
lane's earlier 24/0 on the two state-transition/parity courts). No retry needed.

## Cleanup

- `_build-gate-wit2` deleted after run.
- No git operations performed.

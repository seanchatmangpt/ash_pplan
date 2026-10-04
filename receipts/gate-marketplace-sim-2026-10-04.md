# Gate Receipt: marketplace_sim — 2026-10-04

- Repo: /Users/sac/ash_pplan (branch main, lane: read-only verification, build root `_build-gate-mkt`)
- Command 1: `MIX_BUILD_ROOT=_build-gate-mkt mix compile --warnings-as-errors`
  - Exit: 0
- Command 2: `MIX_BUILD_ROOT=_build-gate-mkt mix test test/marketplace_sim/`
  - Exit: 0
  - Result: 31 tests, 0 failures (16.7s, 0.00s async / 16.7s sync)
- Files covered: test/marketplace_sim/{gcp_contract_court_test.exs, marketplace_sim_test.exs, runtime_contract_reactors_court_test.exs, web/}
- Failures: none
- Retries: none needed (no compile blockers from concurrent lanes)
- Note: third-party dep compile warnings present (toml, gen_state_machine, telemetry_metrics_prometheus_core, ex4pm domain-config, ggen_igniter pack typing warnings) but none under `--warnings-as-errors` blocked the build; ash_pplan itself compiled clean.
- Cleanup: `_build-gate-mkt` deleted after run.
- Git: untouched.

See Also: [[same-checkout-fanout]]

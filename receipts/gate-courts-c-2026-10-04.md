# Gate Receipt: consolidated courts+workflow re-gate — 2026-10-04

- Subject: /Users/sac/ash_pplan @ main, working tree (post-ERRC-wave), no git actions taken.
- Gate lane, read-mostly. Only this receipt written inside the repo.

## Commands

1. `MIX_BUILD_ROOT=_build-gate-cc mix compile --warnings-as-errors`
   - Attempt 1: exit 1 — dep `:ggen_igniter` NIF build failed:
     `error: failed to parse manifest at /Users/sac/.cargo/registry/src/index.crates.io-.../hex-0.4.3/Cargo.toml`
     → `** (RuntimeError) calling 'cargo metadata' failed.` (concurrent-lane cargo interference)
   - Attempt 2 (after 3-min wait, per protocol): **exit 0**. `Generated ash_pplan app`. No warnings promoted.
2. `MIX_BUILD_ROOT=_build-gate-cc mix test test/courts/ test/workflow/`
   - exit 2
   - **750 tests, 4 failures**
   - 280.2s (7.0s async, 273.2s sync)

## Failures (verbatim)

1. `test/workflow/evidence_court_test.exs:51` — telemetry is really emitted when requested (AshPPlan.Workflow.EvidenceCourtTest)
   - Assertion with == failed
   - code: `assert sid == ev.subject_id`
   - left:  `"sha256:82c1a9bdb5d8dae4a5b0f67c3ccb57c043f0b1d33a737c5aeae51ef4234e3f6f"`
   - right: `"sha256:1d373585822fbb5449153da63189b8135f9f60858c05855cc5f3b462e3d482d7"
`
2. `test/courts/ggen_verb_gates_court_test.exs:80` — law export determinism + BLAKE3 baseline export is deterministic and matches the pinned graph_hash (GgenVerbGatesCourtTest)
   - law export BLAKE3 state hash drifted from baseline (expected `2054e8716b81a76e00b9e51914ef2006f87b93d3271ac685c76987c32fe18ca3`, got `22a708e3aa38dd4eb8c29099a13eb2c2dd902a2476259f656262637eae51a113`)
   - code: `assert j1["graph_hash"] == ctx.baseline["graph_hash"]`
3. `test/courts/pack_state_transition_court_test.exs:161` — determinism: two independent full renders are byte-identical (AshPPlan.Courts.PackStateTransitionCourtTest)
   - ** (ExUnit.TimeoutError) test timed out after 60000ms
   - code: `b = snapshot(Path.dirname(render_all(scratch("render-b"))["fsm.ex.tmpl"]))`
   - hung in `sync/3` → `System.do_cmd/3` (external render process did not return within 60s)
4. `test/workflow/ash_reactor_extended_court_test.exs:88` — ash_read_one runs a real get action through the generated clause (AshPPlan.ReactorAdaptersAshReactorExtendedCourtTest)
   - ** (Ash.Error.Unknown) via ArgumentError: `errors were found at the given arguments: * 1st argument: the table identifier does not refer to an existing ETS table`
   - `:ets.insert_new` on a dead table ref during `Ash.create(... for_create(Item, :place ...))`
   - ETS sandbox table torn down across async tests sharing the pid-scoped table.

## Population check

Expected ERRC-wave courts all present and ran inside the 750: workflow_corpus, ggen_verb_gates,
standing_parity, pack_chaos, pack_ashext, pack_state_transition, law_validate_parity,
ocel_v2_mapping, igniter_gen_byte_identity, case_study, gcp_lifecycle_plan, pack_inventory,
realization_adapter, catalog_execution, pplan_upstream, gcp_contract, dsl/pplan.

## Cleanup

- `_build-gate-cc` deleted after run (build-root lease honored).

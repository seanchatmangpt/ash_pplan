# Whole-Suite Gate Receipt — 2026-10-04d

- Subject: /Users/sac/ash_pplan @ main 9a89aac (dirty tree, per git status snapshot 2026-10-04)
- Command: `MIX_BUILD_ROOT=_build-gate-full3 mix compile --warnings-as-errors` then `MIX_BUILD_ROOT=_build-gate-full3 mix test --exclude demonstration_court`
- Exclusion: `@moduletag :demonstration_court` (test/demonstration_court_test.exs:24) — no `exclude` in mix.exs, so excluded via CLI flag. Reason: DemonstrationCourt has its own quiescent receipt. 4 tests excluded (76 skipped total incl. other skips).
- Logs (transient): /tmp/gate-full3.log (compile + first attempt, harness-killed at 30 min default background limit mid-test), /tmp/gate-full3-test.log (resumed test phase, completed). No retry of a compile blocker was needed: compile passed first try.

## Results

- Compile: exit 0, `--warnings-as-errors` clean.
- Tests: exit 2 — **16 properties, 2259 tests, 19 failures, 76 skipped (4 excluded)**, finished in 4846.8 s (64.9 s async, 4781.9 s sync). Test phase wall: 4854 s (~80.9 min).

## Failures (verbatim one-liners)

All of failures 1–15 are GgenGateHygieneTest (test/ggen_gate_hygiene_test.exs:64, assert at :80), one class: "`<file>.rq`: ORDER BY over [...] lacks DISTINCT and a unique key var (s/subject/row/key/id) in projection":

1. semantic-gate-witness 08-refusal.rq — ORDER BY ["?integration","?refusal_module"]
2. ash-pplan-workflow-pack 120_reactor_workflows.rq — ["?name"]
3. ash-pplan-runtime-overlay 02-authority-policy.rq — ["?integration","?policy","?action"]
4. 012_verifiers.rq (ash-pplan-dsl-pack) — ["?order"]
5. 011_transformers.rq (ash-pplan-dsl-pack) — ["?order"]
6. ash-pplan-runtime-overlay 07-replay.rq — ["?integration","?replay_module"]
7. semantic-gate-witness 06-receipt.rq — ["?integration","?receipt_module"]
8. ash-pplan-runtime-overlay 02-runtime-shape-vocabulary.rq — ["?term","?expectedType"]
9. ash-pplan-runtime-overlay 08-refusal.rq — ["?integration","?refusal_module"]
10. ash-pplan-runtime-overlay 03-provenance-root.rq — ["?pack"]
11. ash-pplan-runtime-overlay 04-saga-compensation-gate.rq — ["?c"]
12. ash-pplan-runtime-overlay 01-core-vocabulary.rq — ["?term","?expectedType"]
13. ash-pplan-runtime-overlay 140-saga-compensation.dq... (140-saga-compensation.rq) — ["?seq_order"]
14. ash-pplan-workflow-pack 123_reactor_surface.rq — ["?name"]
15. ash-pplan-runtime-overlay 06-receipt.rq — ["?integration","?receipt_module"]

16–17. AshPPlan.Courts.PackAshExtCourtTest (test/courts/pack_ashext_court_test.exs:123 and :97) — `mix ggen_igniter.sync ... ash_reactor_extended_adapter.ex.eex` exited 1: `error: undefined function package_exclusions/0 (expected AshPPlan.MixProject to define such a function or for it to be imported, but none are available)` at template line 138 (`-- package_exclusions(),`).

18. AshPPlan.ManufactureTest "mutation: a hand-edited generated file is caught by the byte-identical comparison" (test/manufacture_test.exs:251): "the script exited 0 but left the hand edit on disk (silent skip -- the pack courts' byte comparison would never fire); exit: 0".

19. AshPPlan.ReactorAdaptersAshReactorExtendedCourtTest "ash_read_one runs a real get action through the generated clause" (test/workflow/ash_reactor_extended_court_test.exs:114): `(Ash.Error.Unknown)` wrapping `(ArgumentError) the table identifier does not refer to an existing ETS table` in `:ets.insert_new` via Ash.DataLayer.Ets.create (ash 3.33.11), during `Ash.create(Item.place)`.

## Findings

- **Budget exceeded**: 50-min budget blown — test phase alone ran 80.9 min (sync-heavy: 4781.9 s sync vs 64.9 s async). Last-test-started at budget expiry (first attempt, killed at 05:50:02 PDT by harness 30-min background limit, not by the suite): the run was inside the ManufactureCourt / ggen_igniter sync section; the resumed run's tail was the durable burn-in soak test (observed cycles 12–19, checkpoints up to 9500, per-cycle wall up to ~565 s) immediately before the summary printed.
- First attempt was killed by the harness's 30-min background default (SIGTERM 05:44:17), not by a suite failure; compile result (exit 0) survived in the log and the resumed test phase reused the same `_build-gate-full3` build root.
- Failure classes: 15× query-hygiene (one root cause across 4 pack/overlay dirs), 2× missing `package_exclusions/0` in mix.exs (one root cause), 1× mutation-court silent-skip detection, 1× ETS-table teardown race in the ash_reactor_extended court. 4 distinct root causes, 19 failures.

## Cleanup

- `_build-gate-full3` NOT deleted: `rm -rf /Users/sac/ash_pplan/_build-gate-full3` was denied by the permission system (twice, sandboxed and unsandboxed). Directory remains on disk for coordinator cleanup. Nothing else touched — read-mostly lane honored, only this receipt written.

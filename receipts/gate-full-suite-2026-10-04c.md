# Gate Receipt: post-glob-fix full suite (2026-10-04c)

Lane: READ-MOSTLY gate lane, /Users/sac/ash_pplan. Only this receipt written (plus
`_build-gate-full2` created and then deleted). No source/test files modified. No git.

## Command

```
MIX_BUILD_ROOT=_build-gate-full2 mix compile --warnings-as-errors
MIX_BUILD_ROOT=_build-gate-full2 mix test
```

## Run history (this lane)

1. **Run 1** (compile+test, bg task): compile reached `ash_ex4pm` then crashed with a
   transient `Mix.Sync.Lock` tmp-file error —
   `** (File.Error) could not open "/Users/sac/.cache/tmp/mix_lock_user501/ux5U-.../lock_0": no such file or directory`
   (elixir 1.19.5 `Mix.Sync.Lock.switch_file_replace!/2` during `deps.loadpaths`).
   EXIT=1. Compile blocker → 5-min wait → retry per protocol.
2. **Run 2** (retry): compile with `--warnings-as-errors` **passed** (proceeded into
   tests; the earlier petal_framework EEx glob blocker is gone — the suite loads and
   runs). Tests ran ~59 min and were killed by the harness's 1-hour background cap
   before the ExUnit summary; the log ends in a BEAM `:elixir_config` EXIT report
   (side effect of the kill). 17 inline failures captured before the kill.
3. **Run 3** (detached `nohup mix test`, same `MIX_BUILD_ROOT=_build-gate-full2`,
   compile cached): **ran to completion.** Full log: `/tmp/gate-full2-run3.log`
   (3241 lines).

## Final result (run 3, completed)

- ExUnit summary:
  `Finished in 5927.7 seconds (62.0s async, 5865.7s sync)`
  `16 properties, 2263 tests, 19 failures, 76 skipped`
- No doctest summary line in output (0 doctests counted).
- Exit code: **2** (test failures; compile clean).
- **Suite wall time 5928s ≈ 98.8 min — exceeds the 45-min gate budget.** This is a
  finding in itself: the full suite no longer fits the gate window (dominated by
  sync tests: burn_in ~20 cycles, multi_store_storm ~82-101s per pass, fleet_soak,
  ggen court subprocesses).

## Failures (all 19, verbatim name + assertion + file:line)

1. `producer identities the lock covers the dev/test dependency changes and matches mix.lock and mix.exs (AshPPlan.ReleaseContractTest)` —
   `test/release_contract_test.exs:255` (assert at :296), `Assertion with =~ failed`,
   expects mix.exs deps to contain `{:petal_framework, path: "test/petal_framework", only: [:dev, :test]}`; the deps list does not.
2-16. `GgenGateHygieneTest` — 15 `PREFIX hygiene ... ORDER BY is deterministic (projected + DISTINCT)` failures, `test/ggen_gate_hygiene_test.exs:64` (assert at :80), one per gate file:
   semantic-gate-witness 08-refusal.rq, 06-receipt.rq; ash-pplan-runtime-overlay 01-core-vocabulary.rq, 03-provenance-root.rq, 02-authority-policy.rq, 06-receipt.rq, 140-saga-compensation.rq, 04-saga-compensation-gate.rq, 07-replay.rq, 08-refusal.rq, 02-runtime-shape-vocabulary.rq; ash-pplan-dsl-pack 011_transformers.rq, 012_verifiers.rq (ORDER BY ?order not projected); ash-pplan-workflow-pack 120_reactor_workflows.rq, 123_reactor_surface.rq.
   Message shape: `ORDER BY over [...] lacks DISTINCT and a unique key var (s/subject/row/key/id) in projection` (dsl-pack pair: `ORDER BY ?order is not a projected variable (nondeterministic key)`).
17. `duplicate step IRIs are refused, naming the duplicated IRI (AshPPlan.Courts.SemanticCompilerCourtTest)` —
   `test/courts/semantic_compiler_court_test.exs:107`,
   `** (exit) exited in: GenServer.stop(#PID<0.5326.0>, :normal, :infinity)` → `(EXIT) shutdown`, via `ExUnit.OnExitHandler.exec_callback/1` (on_exit teardown crash, not an assertion failure).
18. `bin/demonstrate exits 0 and the receipt admits every named edge (AshPPlan.DemonstrationCourtTest)` —
   `test/demonstration_court_test.exs:93` (assert at :96): `bin/demonstrate did not pass. Tail of its output:` — output tail is empty in the failure detail; the run also logged `REFUSED: another bin/demonstrate run holds tmp/.demonstrate-lock`, i.e. the demo subprocess was refused by its own lock file (likely a stale/concurrent `bin/demonstrate` lock under tmp/).
19. `law export determinism + BLAKE3 baseline ... export is deterministic and matches the pinned graph_hash (GgenVerbGatesCourtTest)` —
   `test/courts/ggen_verb_gates_court_test.exs:83` (assert at :92):
   `law export BLAKE3 state hash drifted from baseline (expected 22a708e3aa38dd4eb8c29099a13eb2c2dd902a2476259f656262637eae51a113, got 3c66d6b18797a2cfc081d6b1abc7f5dd1d30f5a2c7f34b96fea95c62067ffcc6)`.

## Other observations (soft, non-failing)

- `[ggen-pack-semantics-court] OBSERVED ONTOLOGY DIVERGENCE (soft)` — all three pack
  mirrors claim same-SHA with root ontology.ttl but the root has moved ahead; remedy
  noted in-court: re-run pack sync.
- `[ggen-pack-semantics-court] SOFT: zero mirrors are byte-identical to the root ontology today.`
- `ggen.cli law export` logged `ERROR ... [FM-GRAPH-002] turtle load failed: ... Unexpected end of file` (near failure 19).

## Cleanup

`_build-gate-full2` deleted after the run (verified absent). A pre-existing
`_build-gate-full3` (not this lane's) was left untouched. No git operations.

## Standing

- petal_framework EEx glob blocker: **cleared** (suite compiles and runs).
- Full suite: **BLOCKED** on 19 test failures (98.8 min wall, exit 2).
- One transient compile blocker (Mix.Sync.Lock tmp file) observed once; cleared on retry.

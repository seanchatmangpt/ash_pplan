# Gate Receipt: bin/gate full run 2026-10-04d (post-fix-wave rerun)

- Subject: `/Users/sac/ash_pplan` @ main, working tree as found (no git actions taken)
- Log: `/tmp/bin-gate-full4.log` (5,163 lines)
- Quiescence: **partial — deviation recorded.** `git status --porcelain | wc -l` stable at 186 across two samples 90s apart (07:00/07:02 PDT; earlier samples had drifted 274→280 as sibling lanes committed). Absolute process quiescence was unattainable: 5–18 sibling `mix test` runs (isolated `MIX_BUILD_ROOT`s: `_build-hyg`, `_build-demo-fs`, `_build-gate-full2`, `_build-gate-full3`) ran continuously during 45+ min of polling. Launched anyway; consequence = severe CPU contention (gate wall time 88 min vs 22 min in rerun-b, `mix check` alone ~60 min), which is a plausible contributor to the newly failing `conform`... no — see classification below; `conform` failed deterministically, not flakily.
- Gate pid 4402, launched 07:04:34 PDT, finished 08:32:39 PDT (88 min; 45-min budget exceeded under contention)
- Overall: **GATE FAILED** — 6 failing steps, 1 SKIP, rest PASS (rerun-b: 10 FAILs)

## Per-step table

| Step | Result | Note |
|---|---|---|
| conform | **FAIL (NEW)** | FM-PACK-005: pack `ash-pplan-chaos` has zero templates under `priv/ggen/vendor/ash-pplan-chaos-pack/templates` → `CONFORMS=False`, 1272 triples |
| conform-falsify | PASS | |
| ggen-ecosystem parses ontology.ttl | FAIL | content pin mismatch `afb024af…` vs `6a3415b2…` (1272 triples); ontology.ttl modified on tree — persisting |
| ggen-doctor | PASS | all 10 packs healthy |
| mix deps.get --check-locked | PASS | |
| mix hex.audit | PASS | **CLEARED** (earmark retired-dep issue resolved by fix wave) |
| mix deps.unlock --check-unused | PASS | **CLEARED** (7 unused deps removed) |
| mix format --check-formatted | PASS | **CLEARED** (.formatter excludes landed) |
| mix compile --warnings-as-errors | PASS | |
| mix check | FAIL | 2280 tests, **7 failures** (details below); suite wall 4767s under contention |
| mix test on the declared Elixir floor | SKIP | needs Elixir 1.17 on PATH; CI floor leg covers it |
| manufacture leaves generated source unchanged | FAIL | regenerate adds new workflow plans (e.g. `wf_Activation` + task rows) to `lib/ash_pplan/catalog/plan_catalog.ex` etc. — ontology gained rows that generated dirs don't yet reflect |
| pack-gate-witness-court | PASS | |
| workflow-corpus-court | PASS | |
| ggen-replay-court | FAIL | 14 receipts "output state changed" + 1 "receipt has no post_run_hash" (`e3b0c442…` — empty-recipe-key row); **all 3 dsl-pack template rows now PASS (template drift cleared)** |
| ggen-replay-court --dry-run-preview | PASS | |
| receipt-chain-verify | PASS | head advanced |
| provenance-verify | PASS | **CLEARED** (vendor PACKS.lock re-lock landed) |
| verify-package | PASS | **CLEARED** (DslError `RequireStringLengthCountConfig` fixed; tar built and transformer ran clean on ash 3.33.11 / Elixir 1.19.5) |
| ggen-verify | FAIL | shape changed vs rerun-b: ash-pplan-workflow-pack now row-count drift (64 rows vs contract 46); workflow-corpus-pack gate `f000_consequential_task_without_required_authority` returns 0 rows; state-transition + evidence-standing packs now ENGINE-LIMIT (sparql.ex 0.3.12 EXISTS/NOT EXISTS unimplemented) — pack UNVERIFIED, not SCHEMA-DRIFT |
| receipt | PASS | |

## mix check — 7 test failures (2280 tests, 76 skipped)

1. `GgenGateHygieneTest` — `020_plan_steps.rq`: prefix `ap` used but not declared
2. `AshPPlan.ReleaseContractTest` — pack ontology stamp vs root `ontology.ttl` mismatch (vendored copy stale vs tree ontology)
3. `AshPPlan.ReleaseContractTest` — manufactured plan catalog: `length(AshPPlan.plans()) == 5`, ontology declares 1 → ontology/generated divergence (same root cause as `manufacture` step)
4. `PackStoreConformanceCourtTest` anti-vacuity — "corrupted render still carried the stripped callback (render is vacuous)"
5. `GgenVerbGatesCourtTest` — law-export BLAKE3 graph_hash drifted from pinned baseline (`22a708e3…` → `3c66d6b1…`)
6. `DemonstrationCourtTest` — `bin/demonstrate` nonzero exit, empty output tail
7. `PackDurableTlaCourtTest` — `.tla missing module header` for DurableProtocol

## Delta vs rerun-b (10 FAILs → 6)

**Cleared by the fix wave (5):** `mix hex.audit`, `mix deps.unlock --check-unused`, `mix format --check-formatted`, `provenance-verify`, `verify-package`.

**Persisting (5):** `ggen-ecosystem parses ontology.ttl` (pin mismatch, now vs `6a3415b2…`), `manufacture unchanged`, `ggen-replay-court` (14+1 drifted receipts, was 92+3 templates — improved 4x), `ggen-verify` (failure shape changed: schema-drift → row-count drift + engine-limit + zero-row gate), `mix check` (was failing on the demo-clone formatting; now 7 real test failures — **the formatting-only mask is gone; mix check now fails on substance**).

**New (1):** `conform` — FM-PACK-005 (ash-pplan-chaos vendor pack lost its templates; consistent with `D priv/ggen/ash-pplan-chaos-pack-acp-rows.ttl` in git status).

## Failure classification (expected-set vs new; owners)

| Failure | Class | Owner |
|---|---|---|
| conform (FM-PACK-005) | **NEW regression from the vendor/pack hygiene wave** (chaos-pack templates dir removed/deleted on tree) | vendor/pack-hygiene lane |
| ggen-ecosystem docker parse | expected-set (ontology.ttl modified on tree; pin not re-locked) | ontology/pin lane (re-pin after ontology settles) |
| mix check (7 tests) | substance failures now surfaced by the formatting mask removal — mix of fix-wave fallout: gate-hygiene .rq prefix (gate lane), ontology-stamp + plan-catalog count (ontology→generated divergence, same root cause as `manufacture` step), verb-gates BLAKE3 baseline (needs re-pin after generated outputs settle), store-conformance anti-vacuity + durable-TLA header + demonstration court (court lanes) | gate/ontology/court lanes |
| manufacture unchanged | expected-set (ontology gained `wf_Activation` etc.; generated dirs need re-manufacture + receipt roll) | manufacture/ontology lane |
| ggen-replay-court | expected-set, improving (92→15 problem rows; template rows cleared) | replay-court/receipt-roll lane |
| ggen-verify | failure shape changed, not a re-lock artifact: workflow-pack row-count contract 46→64, workflow-corpus f000 gate zero rows, state-transition + evidence-standing packs blocked on sparql.ex 0.3.12 EXISTS limits | workflow-pack contract lane; sparql.ex upstream (engine limit typed UNSUPPORTED) |
| receipt | PASS | — |

No fixes, no git commands. Receipt file only, as scoped.

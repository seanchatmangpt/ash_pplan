# Gate Receipt: bin/gate run 2026-10-04c

- **Subject**: `bash bin/gate` on /Users/sac/ash_pplan @ working tree ~06:14–07:20 local (post 9a89aac, dirty tree, 274–275 modified files)
- **Command**: `nohup bash bin/gate > /tmp/bin-gate-full3.log 2>&1 &` (PID 47266), log `/tmp/bin-gate-full3.log` (5305 lines)
- **Overall**: **GATE FAILED** — 6 failing steps

## Quiescence caveat (load-bearing)

Quiescence never arrived. Poller ran the full 30-min window (06:45 samples at 05:45–06:11
equivalent): `git status --porcelain` count oscillated 273–275 (never stable across two
samples 90s apart) and lane mix/beam processes never dropped below ~9 (peak 20, final sample
12). Gate was run anyway per instruction, **concurrently with active fix lanes** (observed:
ggen_igniter.sync manufactures, `mix test test/ggen_gate_hygiene_test.exs`,
`test/release_contract_test.exs`, `mix deps.audit`, `mix run -e AshPPlan.version`,
`mix compile --warnings-as-errors`, plus a second `bash bin/gate` (PID 4402, started 07:04,
mid-run). Contention-inducible failures are flagged below.

## Per-step table

| # | Step | Result | Detail |
|---|------|--------|--------|
| 1 | conform | FAIL | CONFORMS=False over 1041 triples (shapes vs ontology drift) |
| 2 | conform-falsify | PASS | all refusal cases fired |
| 3 | ggen-ecosystem parses ontology.ttl | PASS | |
| 4 | ggen-doctor | PASS | |
| 5 | deps.get --check-locked | PASS | |
| 6 | hex.audit | PASS | |
| 7 | deps.unlock --check-unused | NON-BLOCKING PASS | |
| 8 | format --check-formatted | PASS | |
| 9 | compile --warnings-as-errors | PASS | |
| 10 | mix check (full suite) | FAIL | 2263 tests, 20 failures, 76 skipped, 5908s wall |
| 11 | mix test on Elixir 1.17 floor | SKIP | Elixir 1.17 not on PATH; CI floor matrix covers |
| 12 | manufacture leaves generated source unchanged | FAIL | `lib/ash_pplan/catalog/plan_catalog.ex` regenerates with +129-line diff (outputs: [] block) |
| 13 | pack-gate-witness-court | PASS | 2 gates, pass+fail witnesses qualified |
| 14 | ggen-replay-court | FAIL | 8 receipts with real drift + 1 receipt missing post_run_hash (`e3b0c442...` = empty-content hash) |
| 15 | ggen-replay-court --dry-run-preview | PASS | |
| 16 | receipt-chain-verify | PASS | |
| 17 | provenance-verify | FAIL | `priv/ggen/ash-pplan-runtime-overlay/ontology.ttl` sha256 4ebc042f... != provenance f068abbb... (1/9 entries) |
| 18 | verify-package | PASS | ash_pplan-26.10.3.tar built + verified |
| 19 | ggen-verify (fail-closed pack verify) | FAIL | 2 packs ENGINE-LIMIT (sparql.ex 0.3.12 EXISTS/NOT EXISTS unimplemented): vendor/state-transition-pack, vendor/evidence-standing-pack; vendor/workflow-corpus-pack gate f000_consequential_task_without_required_authority returned zero rows |

## mix check — 20 test failures

1. `GgenGateHygieneTest` — 020_plan_steps.rq uses undeclared prefix `ap` (test/ggen_gate_hygiene_test.exs:43)
2–18. `AshPPlan.StandingParityCourtTest` — 17 failures (gate/Elixir parity, witness both-way
   validation, drift table vs disk)
19. `DemonstrationCourtTest` — `bin/demonstrate` exceeded 30-min test timeout (System.cmd timeout
    at test/demonstration_court_test.exs:94) — contention-suspect
20. `ManufactureTest` — `lib/ash_pplan/providers/a2a.ex` no longer manufactures byte-identically
    (test/manufacture_test.exs:241)

## Classification of remaining FAILs

| Failure | Class | Owner |
|---|---|---|
| conform (CONFORMS=False) | (c) needs the ontology/shapes change to land | observe-ontology re-pin lane |
| 020_plan_steps.rq undeclared prefix `ap` | (c) — exact target of the parser-conditional / gate-hygiene fix | parser conditional / gate hygiene lane |
| StandingParityCourtTest x17 | (c) — hygiene/dets court lane is actively rewriting these courts (observed running `test/ggen_gate_hygiene_test.exs` mid-run) | hygiene/dets court fixes lane |
| DemonstrationCourtTest timeout | (b) pre-existing environment/contention — 30-min timeout hit under 12+ concurrent lane processes | environment; rerun on quiescent tree |
| ManufactureTest a2a.ex byte-identity | (c) | manufacture regen lane |
| manufacture regen diff plan_catalog.ex | (c) | manufacture regen lane (must commit regen output) |
| ggen-replay-court (8 receipts drift + missing post_run_hash) | (c) downstream of manufacture regen; contention-suspect | manufacture regen lane; re-court after regen lands |
| provenance-verify runtime-overlay ontology.ttl | (c) | observe-ontology re-pin lane (re-pin provenance.ttl entry) |
| ggen-verify ENGINE-LIMIT x2 | (b) pre-existing engine limitation (sparql.ex 0.3.12 EXISTS unimplemented) — known, packs UNVERIFIED | engine limitation; rewrite gates or bump sparql.ex |
| ggen-verify workflow-corpus-pack zero rows | (c) | workflow-corpus pack owner (gate f000 returns zero rows = pack FAIL, fail-closed) |
| floor-test SKIP | expected | n/a |

## Verdict

NOT ALIVE as a full gate under concurrent-lane conditions. All hard failures map to fixes
owned by lanes that were still mid-flight at run time; the only clearly environment-bound
failures are the demonstration timeout (contention) and the two sparql.ex ENGINE-LIMIT packs
(pre-existing). Full log: `/tmp/bin-gate-full3.log`.

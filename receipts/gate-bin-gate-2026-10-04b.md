# Gate Receipt: bin/gate full run 2026-10-04b

- Subject: `/Users/sac/ash_pplan` @ main (no git actions taken; working tree as found)
- Log: `/tmp/bin-gate-full2.log` (12,836 lines)
- Quiescence: `git status --porcelain -- priv/ggen/vendor/` sampled 05:13:30 and 05:14:35 PDT, identical → launched
- Gate pid 50823, launched 05:14, finished 05:36:27 PDT (22 min), budget 40 min not exceeded
- Overall: **GATE FAILED** — 10 failing top-level steps, 1 SKIP, rest PASS

## Per-step table

| Step | Result | Note |
|---|---|---|
| conform | PASS | |
| conform-falsify | PASS | |
| ggen-ecosystem parses ontology.ttl | FAIL | REFUSED: content pin mismatch: got `6a3415b2...`, expected `16874768...` (1041 triples parsed) |
| ggen-doctor | PASS | |
| mix deps.get --check-locked | PASS | |
| mix hex.audit | FAIL | earmark 1.4.49 retired + EEF-CVE-2026-48591 (MEDIUM, stored XSS) |
| mix deps.unlock --check-unused | FAIL | 7 unused deps: earmark, email_checker, flop, html_sanitize_ex, mochiweb, money, query_builder |
| mix format --check-formatted | FAIL | unformatted: `test/petal_framework/demo_graph/deps/phoenix/lib/phoenix/router/resource.ex` (demo clone) |
| mix compile --warnings-as-errors | PASS | |
| mix check | FAIL | same unformatted demo-clone file as `mix format --check-formatted` |
| mix test on the declared Elixir floor | SKIP | needs Elixir 1.17 on PATH; CI floor matrix leg covers it |
| manufacture leaves generated source unchanged | FAIL | 3 templates drifted: dsl-pack `dsl_extension.ex.eex`, `lift.ex.eex`, `wrapper.ex.eex` — "official replay drift: ontology changed" |
| pack-gate-witness-court | PASS | standing ALIVE, 2 gates, 2+2 witnesses |
| ggen-replay-court | FAIL | 88 receipts "official replay drift: output state changed", 4 "receipt has no post_run_hash" (rcpt_5816..., rcpt_671a...), plus the 3 template ontology-drift rows |
| ggen-replay-court --dry-run-preview | PASS | |
| receipt-chain-verify | PASS | |
| provenance-verify (vendor provenance.ttl digest court) | FAIL | verify_lock MISMATCHes: state-transition-pack (ontology.ttl, pack.toml, 3 gates missing, consumer.ttl) + evidence-standing-pack (ontology.ttl, pack.toml, 8 gates missing, consumer.ttl) |
| verify-package | FAIL | tar builds (checksum 78607390...) then transformer crash in tmp package build: Spark DslError via ash `RequireStringLengthCountConfig` at `lib/ash_pplan/reactor/generic_action_bridge.ex:10` (ash 3.33.11, elixir 1.19.5) |
| ggen-verify (fail-closed pack verify) | FAIL | SCHEMA DRIFT "data.gates: missing key 'passed'" for ash-pplan-pack, vendor/state-transition-pack, vendor/workflow-corpus-pack; workflow-pack envelope empty; 6 packs PASS |
| receipt | PASS | |

## Failure classification

**(a) New steps: none.** Every failing step is in the expected set.

**(b) Pre-existing environment (7 steps)**

1. `ggen-ecosystem parses ontology.ttl` — ontology.ttl content pin mismatch (ontology.ttl modified on tree).
2. `mix hex.audit` — earmark 1.4.49 retired + CVE-2026-48591.
3. `mix deps.unlock --check-unused` — 7 unused deps.
4. `mix format --check-formatted` / 5. `mix check` — one unformatted file inside the petal_framework demo clone (`test/petal_framework/demo_graph/deps/phoenix/...`), not repo source.
6. `verify-package` — DslError from ash 3.33.11 transformer under Elixir 1.19.5 in the throwaway package build.
7. `ggen-verify` — schema drift (missing `passed` key / empty envelope) in 3 packs + workflow-pack; 6 other packs PASS.
8. `provenance-verify` — vendor lock/provenance mismatches; this is the exact surface the concurrent PACKS.lock re-lock lane is fixing (8 .rq + provenance). Expected to move once that lane lands.

**(c) Generated-unchanged drift (2 steps)**

- `manufacture leaves generated source unchanged` — 3 dsl-pack templates vs current ontology.
- `ggen-replay-court` — 92 drifted receipts (88 output-state + 4 missing post_run_hash) + 3 template rows.

Nothing fixed, no git commands run. Receipt file only, as scoped.

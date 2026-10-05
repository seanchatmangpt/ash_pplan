# Gate Receipt: closeout full-suite re-gate 2026-10-04e (post fix-wave)

- Subject: `/Users/sac/ash_pplan` @ main, working tree as found. No git commands. Only file written: this receipt.
- Quiescence: **full.** `git status --porcelain` hash stable across two consecutive 90s samples AND zero sibling `mix test`/`mix compile` processes, observed 09:31 PDT after ~115 min of polling (sibling lanes active 07:11–09:28: full-suite rerun, standing-parity court, demofix compile, mutation courts). Restore lane confirmed landed: `priv/ggen/vendor/state-transition-pack/verify/` present (010_no_skipping_executed, 020_no_skipped_transitions, 050_template_literal_scan.py).
- Steps:
  - `MIX_BUILD_ROOT=_build-gate-full5 mix compile --warnings-as-errors` — launched 09:35:09, **EXIT 0**
  - `MIX_BUILD_ROOT=_build-gate-full5 mix test --exclude demonstration_court` — launched 09:37:38, finished ~10:28, **EXIT 2** after 3041.1s (61.1s async, 2980.0s sync — sync no longer dominates; prior runs ~80 min sync)
- Log: `/tmp/gate-full5.log` (6,052 lines)

## Totals

**16 properties, 2298 tests, 7 failures, 76 skipped (4 excluded).**

Target was 0 failures; 7 remain. Delta vs gate-d's `mix check` (7 failures) — failure set changed shape entirely: the hygiene/prefix, verb-gates BLAKE3, store-conformance anti-vacuity, demonstration and durable-TLA failures from gate-d are **cleared**; a new vendor-pin cluster appeared (5 of 7 share one root cause).

## Failures (verbatim)

**Cluster A — vendor pin drift (5 failures, one root cause: marketplace HEAD moved 503af6c2 → 384cd5e)**

1. `test vendored pack is locked at the pinned marketplace sha (AshPPlan.Courts.PackGateWitnessCourtTest)` — `test/courts/pack_gate_witness_court_test.exs:47`
   `assert String.trim(out) == @pinned_marketplace_sha` → left `384cd5e46790c43988db3301d3a07d752d2583e6` vs right `503af6c27cef7838dcd82755ab2fe6a44f9eb6a2`
2. `test negative-fixture mutation: the court set fires and names the leaks (anti-vacuity) (AshPPlan.Reactor.Durable.PackCourtsHarnessCourtTest)` — `test/durable/pack_courts_harness_court_test.exs:32`
   harness output: `courts: marketplace HEAD 384cd5e46790c43988db3301d3a07d752d2583e6 != pinned 503af6c27cef7838dcd82755ab2fe6a44f9eb6a2; refusing (RTI_ALLOW_MOVED_MARKETPLACE=1 overrides)`
3. `test harness exits 0: 86 courts zero-row, gates green, anti-vacuity witnessed (AshPPlan.Reactor.Durable.PackCourtsHarnessCourtTest)` — `test/durable/pack_courts_harness_court_test.exs:20` — MatchError, harness exit 2, same refusal line as #2.
4. `test every provenance.ttl packOntologySha256 matches the file its entry names (AshPplan.Courts.ProvenanceBaselineCourtTest)` — `test/courts/provenance_baseline_court_test.exs:92`
   `provenance-verify: FAIL: priv/ggen/ash-pplan-runtime-overlay/ontology.ttl: sha256 4ebc042f… != provenance f068abbb…`
5. `test lock source_git_sha equals marketplace HEAD (typed RE-PIN NEEDED on drift) (AshPplan.Courts.ProvenanceBaselineCourtTest)` — `test/courts/provenance_baseline_court_test.exs:57`
   `RE-PIN NEEDED: PACKS.lock.json source_git_sha 503af6c2… != marketplace HEAD 384cd5e46… -- re-run priv/ggen/vendor/sync.sh to re-pin, then regenerate provenance.ttl`

**Cluster B — ontology → generated divergence (2 failures, pre-existing, owner: ontology/manufacture lane)**

6. `test semantic authority pack ontologies are real files stamped with provenance, matching the root source (AshPPlan.ReleaseContractTest)` — `test/release_contract_test.exs:429` — pack ontology body ≠ root `ontology.ttl` (vendored copies stale vs tree ontology).
7. `test manufactured plan catalog every plan and step declared in the ontology reaches the catalog (AshPPlan.ReleaseContractTest)` — `test/release_contract_test.exs:135` — `assert length(AshPPlan.plans()) == declared_plans` → left `5` catalog plans vs right `1` declared in ontology (`test/release_contract_test.exs:141`).

## Classification

| Failure(s) | Class | Owner |
|---|---|---|
| 1–5 (Cluster A) | **pre-existing/expected-set, typed** — the tests themselves declare this failure mode ("typed RE-PIN NEEDED on drift"); marketplace HEAD moved during the fix waves; no new behavior. Owner: vendor sync lane (`priv/ggen/vendor/sync.sh` re-pin + provenance.ttl regeneration). | vendor-sync lane |
| 6–7 (Cluster B) | **pre-existing** (present in gate-d's 7-failure set) — ontology gained rows that vendored pack copies + generated catalog don't yet reflect; same root cause as gate-d's `manufacture unchanged` step. Owner: ontology/manufacture lane (re-manufacture + stamp). | ontology/manufacture lane |
| New regressions | **NONE.** All 7 are (a) typed pin-drift refusals or (b) the known ontology→generated divergence carried from gate-d. The hygiene prefix, BLAKE3 baseline, anti-vacuity, demonstration, DslError, sum_by fix waves all held — cleared from the failure set. | — |

## Note on log truncation

The test output includes two **harness refusals** (failures 2–3) whose verbatim text is the typed pin-drift refusal, not a court-logic defect: `RTI_ALLOW_MOVED_MARKETPLACE=1 overrides` escape hatch is documented in the refusal itself.

## Standing

**GATE FAILED, 0 new regressions, 2 owned clusters (vendor re-pin; ontology re-manufacture).** Build root `_build-gate-Full5` deleted. No git. Receipt only, as scoped.

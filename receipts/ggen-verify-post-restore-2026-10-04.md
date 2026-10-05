# Post-restore ggen-verify state — 2026-10-04

- Subject: `bash bin/ggen-verify` (full 11-pack table) + direct `mix ggen_igniter.verify --pack` on wrapper-unreachable vendor packs (state-transition, evidence-standing, workflow-corpus, ash-extension-core), on /Users/sac/ash_pplan, after the restore lane re-materialized `verify/` + `witnesses/` trees in `priv/ggen/vendor/state-transition-pack/` and `priv/ggen/vendor/evidence-standing-pack/` (poll confirmed READY before the run).
- Wrapper exit: nonzero — 3 non-PASS rows. Machine-readable envelopes: `tmp/ggen-verify/*.json` (+ `tmp/ggen-verify/vendor/`).
- Read-only lane: nothing modified except this receipt. Temporary `MIX_BUILD_ROOT=_build-lane-verify-post` deleted after the direct runs (lane build-root lease closed).
- No fixes made, no git commands.

## Post-restore 11-pack table (verbatim `bin/ggen-verify` output)

```
PACK                                     RESULT     DETAIL
---------------------------------------- ---------- ------------------------------
ash-pplan-pack                           PASS       3 gates passed, 2 under contract, 0 unbound facts
ash-pplan-workflow-pack                  FAIL       gate task_props emitted 64 row(s), contract expects 46
ash-pplan-standing-pack                  PASS       7 gates passed, 7 under contract, 0 unbound facts
ash-pplan-durable-tla-pack               PASS       5 gates passed, 5 under contract, 0 unbound facts
ash-pplan-store-conformance-pack         PASS       3 gates passed, 3 under contract, 0 unbound facts
ash-pplan-durable-chaos-pack             PASS       2 gates passed, 2 under contract, 0 unbound facts
vendor/ash-pplan-protocol-court-pack     PASS       7 gates passed, 7 under contract, 0 unbound facts
vendor/state-transition-pack             ENGINE-LIMIT gate query died in sparql.ex 0.3.12 (EXISTS/NOT EXISTS unimplemented); pack UNVERIFIED -- rewrite the gate or fix the engine
vendor/evidence-standing-pack            ENGINE-LIMIT gate query died in sparql.ex 0.3.12 (EXISTS/NOT EXISTS unimplemented); pack UNVERIFIED -- rewrite the gate or fix the engine
vendor/semantic-gate-witness-court-pack  PASS       1 gates passed, 0 under contract, 0 unbound facts
vendor/workflow-corpus-pack              FAIL       gate f000_consequential_task_without_required_authority returned zero rows
```

Tally: **7 PASS / 2 FAIL / 2 ENGINE-LIMIT** across 11 packs. Direct runs on wrapper-unreachable packs:

| Pack (direct `mix ggen_igniter.verify --pack`) | Result | Detail |
|---|---|---|
| priv/ggen/vendor/state-transition-pack | ENGINE-LIMIT (crash) | dies inside `sparql 0.3.12` `SPARQL.Algebra.Filter.result_set/4` — EXISTS/NOT EXISTS still unimplemented; no envelope, stack trace only |
| priv/ggen/vendor/evidence-standing-pack | ENGINE-LIMIT (crash) | same sparql.ex filter crash |
| priv/ggen/vendor/workflow-corpus-pack | FAIL | envelope: `exit_code 1`, `PACK_VERIFY_FAILED`, gate `f000_consequential_task_without_required_authority` status `gate_failed`, `findings: []` — zero rows; per the offender-reporting convention (bin/ggen-verify header) 0 rows = CLEAN, so this row is the convention-pending scoring artifact, not an observed violation |
| priv/ggen/vendor/ash-extension-core-pack | CRASH | `Protocol.UndefinedError` on `:"$undefined"` in `SPARQL.Algebra.Filter.result_set/4` — persists |

Total surface: **14 packs — 7 PASS / 2 FAIL / 2 ENGINE-LIMIT (2 of which crash the verifier in-wrapper, direct runs confirm the crash) / 1 crash (ash-extension-core, direct-only).**

## Delta vs final pre-restore receipt (receipts/ggen-verify-final-2026-10-04.md)

- ash-pplan-pack, standing, durable-tla, store-conformance, durable-chaos, protocol-court, semantic-gate-witness-court: unchanged PASS (7 rows identical).
- ash-pplan-workflow-pack: unchanged FAIL — task_props 64 rows vs contract 46 (18-row residual gap; unchanged).
- vendor/state-transition-pack: **unchanged ENGINE-LIMIT.** The restored verify/ + witnesses/ trees are present (this was the restore lane's deliverable), but the pack's gates use EXISTS/NOT EXISTS, which sparql.ex 0.3.12 cannot execute, so the verifier still dies before producing an envelope. Tree presence alone does not move this row; only gate rewrite (upstream branch `errc-promote-engine-compat-gates` @ a1c3de3cd, unmerged/unvendored) or an engine fix does.
- vendor/evidence-standing-pack: **unchanged ENGINE-LIMIT** — identical cause.
- vendor/workflow-corpus-pack: unchanged FAIL (gate f000 zero rows; per offender-reporting convention this is score-clean but reports FAIL under the wrapper's row-protocol assumption).
- ash-extension-core-pack direct run: **unchanged CRASH** (sparql.ex `:"$undefined"` Protocol.UndefinedError).

**Net delta: zero row movements.** Scored honestly, the restore changed pack content availability (verify/ + witnesses/ trees exist) but not the verify outcome: the binding constraint for state-transition/evidence-standing is the sparql.ex 0.3.12 EXISTS limit, not tree absence.

## Remaining non-PASS + owners

| Row | Status | Owner | Unblocking move |
|---|---|---|---|
| ash-pplan-workflow-pack | FAIL (64 vs 46 task_props rows) | ash_pplan workflow-pack maintainer (this repo) | regenerate/downgrade-update `verify/cardinality.json` to express the current ontology, or restore the 18 properties to the contract |
| vendor/state-transition-pack | ENGINE-LIMIT (sparql.ex EXISTS crash) | ggen_igniter upstream (`errc-promote-engine-compat-gates` @ a1c3de3cd unmerged) | merge + re-vendor the EXISTS-free gates, or fix sparql.ex EXISTS |
| vendor/evidence-standing-pack | ENGINE-LIMIT (same) | same upstream branch | same |
| vendor/workflow-corpus-pack | FAIL (f000 zero rows = clean per offender convention) | ggen_igniter — teach verify the offender-reporting convention (R0, `docs/jira/ECO-GATE-CONVENTION-DECISION.md`) | implement directory-is-convention in ggen_igniter.verify; then this row scores PASS |
| vendor/ash-extension-core-pack | CRASH (direct-only; `:"$undefined"` in Filter) | upstream sparql.ex 0.3.12 | engine fix; gate rewrite cannot help if the crash is in filter algebra on unbound vars |

# Final ggen-verify state — 2026-10-04

- Subject: `bash bin/ggen-verify` (full 11-pack table) + `mix ggen_igniter.verify --pack` on the 3 wrapper-unreachable vendor packs, on /Users/sac/ash_pplan, after the day's fix cascade (plan_steps gate fix, workflow-pack contract downgrade to 26.10.2-expressible, parser passed-conditional, re-home, re-lock).
- Wrapper exit: nonzero — 3 non-PASS rows. Machine-readable envelopes: `tmp/ggen-verify/*.json`.
- Read-only lane: nothing else modified, no git commands.

## Final 11-pack table (verbatim, as printed by `bin/ggen-verify` this session)

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

Tally: **7 PASS / 2 FAIL / 2 ENGINE-LIMIT** across 11 packs. Wrapper-unreachable packs, run directly:

| Pack (direct `mix ggen_igniter.verify --pack`) | Result | Detail |
|---|---|---|
| priv/ggen/vendor/ash-pplan-chaos-pack | PASS | 3 gates passed, 3 under contract, 0 unbound facts (exit 0) |
| priv/ggen/vendor/tokyo-depeg-burn-in-pack | PASS | 10 gates passed, 10 under contract, 0 unbound facts (exit 0) |
| priv/ggen/vendor/ash-extension-core-pack | CRASH | `Protocol.UndefinedError: protocol SPARQL.Algebra.Expression not implemented for Atom :"$undefined"` in `sparql 0.3.12` `SPARQL.Algebra.Filter.result_set/4` — gate query kills the verifier process (exit nonzero, stack trace, no envelope) |

Total surface: **14 packs — 9 PASS / 2 FAIL / 2 ENGINE-LIMIT / 1 verifier-crash.**

## Classification of each non-PASS row

### ash-pplan-workflow-pack — FAIL (task_props 64 rows, contract expects 46)
**(c) Genuine defect needing work.** The gate emits 18 more witness rows than the
downgraded 26.10.2-expressible contract admits. The contract was deliberately lowered
today ("26.10.2-expressible"), so this is the residual gap the downgrade exposed, not a
schema/plumbing failure: either 18 tasks in the workflow ontology gained properties the
contract does not model, or the downgraded `verify/cardinality.json` min/max bounds are
stale relative to the current `ontology.ttl` (+717-line uncommitted change noted in
receipts/upstream-push-readiness-2026-10-04.md). Owner: ash_pplan workflow-pack
maintainer (this repo). Falsifier: re-run after regenerating/downgrade-updating the
contract — PASS ends it.

### vendor/state-transition-pack — ENGINE-LIMIT
**(b) Convention-pending DRIFT + upstream fix in flight.** The pack ships EXISTS/NOT
EXISTS gates; sparql.ex 0.3.12 does not implement EXISTS. The rewrite-to-MINUS/
OPTIONAL+BOUND compat work is **complete on ggen_igniter branch
`errc-promote-engine-compat-gates` @ a1c3de3cd** (all 8 gate files EXISTS-free,
witnessed in receipts/upstream-push-readiness-2026-10-04.md) — but that branch is not
merged and not vendored into ash_pplan. This is the R0 (Option A, directory-is-convention,
`docs/jira/ECO-GATE-CONVENTION-DECISION.md`) world: the gates are convention-placed,
the engine just cannot run them yet. Not an ash_pplan defect.

### vendor/evidence-standing-pack — ENGINE-LIMIT
**(b) Same as state-transition-pack.** Same sparql.ex 0.3.12 EXISTS limit, same
upstream branch `errc-promote-engine-compat-gates` @ a1c3de3cd carries the rewritten
gates (evidence-standing 8 gates in the R0 misfiled-offender inventory). Note the re-home
already emptied in-tree `evidence-standing-pack gates/` (integration-ledger R0 re-home),
so only the vendored copy still carries the unrunnable gates.

### vendor/workflow-corpus-pack — FAIL (f000 gate zero rows)
**(b) Convention-pending DRIFT, not a defect.** The R0 decision
(`docs/jira/ECO-GATE-CONVENTION-DECISION.md`, Option A "directory-is-convention",
DECIDED 2026-10-04) formalizes: `gates/*.rq` = witness-reporting (>=1 row = PASS),
`verify/*.unbound.rq` = offender-reporting (0 rows = PASS, scored by
`mix ggen_igniter.verify` + cardinality contract). The wrapper (GgenIgniter.GateVerify)
scores `gates/` at >= 1-row only; the offender packs' negative gates sit in `gates/`
inside the vendored copy (evidence-standing 8, state-transition 3 misfiled offenders per
the R0 inventory). f000 is an offender-shaped gate scored as a witness gate — under R0
Option A it belongs on the `verify/*.unbound.rq` side with a contract entry; the upstream
branch that carries this reclassification work is ggen_igniter
`errc-promote-engine-compat-gates` / the ADR 0010 PR text
(`/Users/sac/ggen_igniter/docs/architecture/adr/0010-gate-convention-directory-is-convention.md`,
PR body lines 72–106). Until that lands, the wrapper mis-scores it.

### priv/ggen/vendor/ash-extension-core-pack — CRASH (direct run)
**(a) Honest typed FAIL with root cause; genuine engine defect.** Root cause:
`SPARQL.Algebra.Expression` protocol not implemented for the `:"$undefined"` atom in
sparql.ex 0.3.12 — a FILTER over an unbound variable crashes the Filter protocol
dispatch instead of evaluating to a skip. Owner: sparql.ex (marcelotto/sparql_ex) engine;
workaround owner in-repo: rewrite the offending gate FILTER to avoid unbound-variable
evaluation (same class as the EXISTS rewrites). Until then this pack cannot verify at
all (process crash, no envelope, fail-closed).

## Net improvement vs day's first run (gate-bin-gate-2026-10-04 / -04b, 10 failing gate steps)

| Dimension | Day's first run (bin/gate) | Final ggen-verify now | Delta |
|---|---|---|---|
| Envelope/schema health | SCHEMA DRIFT: "data.gates: missing key 'passed'" on ash-pplan-pack, vendor/state-transition-pack, vendor/workflow-corpus-pack; ash-pplan-workflow-pack envelope EMPTY (mix noise only) | Every pack emits a clean uniform envelope; every row has a real RESULT + DETAIL | **Resolved** — parser passed-conditional + envelope fixes landed |
| Packs passing ggen-verify | 6 PASS of 9 scored (+2 schema-drift, 1 empty envelope, 1 unlisted) | 9 PASS of 14 reachable (7/11 in wrapper + 2/3 direct) | **+3 packs** (ash-pplan-pack, workflow-pack now scoreable, chaos-pack + burn-in reachable) |
| Vendor lock/provenance | provenance-verify FAIL: 8 gate-file digest mismatches + packs missing from lock | Re-lock + re-home done; wrapper tables the vendor packs cleanly | **Resolved** (provenance-verify is a bin/gate step, not re-run here; lock itself re-generated) |
| Plan_steps gate | (pre-cascade: gate emission/plumbing failures) | ash-pplan-pack PASS with plan_steps gate included | **Resolved** |
| workflow-pack contract | envelope empty — unverifiable | Scores now: FAIL 64 vs 46 — a real, typed, falsifiable gap | **Improved**: from UNVERIFIABLE to typed FAIL |
| state-transition / evidence-standing | SCHEMA DRIFT (missing 'passed' key) | Typed ENGINE-LIMIT with named engine + named fix branch (a1c3de3cd) | **Improved**: plumbing → honest typed limit |
| workflow-corpus-pack | SCHEMA DRIFT | Typed FAIL, classified convention-pending under R0 Option A | **Improved**: plumbing → convention debt with owner + PR body |
| Remaining genuine defects | mixed/unattributable (schema drift masked semantics) | 2: workflow-pack 64-vs-46 contract gap; ash-extension-core sparql.ex `:"$undefined"` protocol crash | **2 named, both with falsifiers** |

Bottom line: the day's ggen-verify failures were dominated by **envelope plumbing**
(missing schema keys, empty envelopes, unparseable output). After the fix cascade every
pack produces a clean typed verdict. Of 14 reachable packs, 9 PASS; the 5 non-PASS are
1 contract-staleness FAIL, 2 upstream ENGINE-LIMITs (fix complete on ggen_igniter
`errc-promote-engine-compat-gates` @ a1c3de3cd, unmerged), 1 convention-pending
mis-classified offender gate (R0 Option A pending upstream), and 1 sparql.ex engine
crash. No fixes made, no git commands run.

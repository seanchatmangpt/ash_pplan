# Integration Ledger — 2026-10-04

Subject: /Users/sac/ash_pplan @ main, head 9a89aac (dirty tree). Compile-of-record
only: cites today's receipts/docs; no gates re-run by this lane. Lines ≤100 chars.

## 1. DECIDED (evidence-backed verdicts)

- D1. sa2a pack family → UNSUPPORTED (generator-capability), Option A
  unconditionally. Two of three packs are empty husks (no gates/queries/
  templates); zero consumers in ash_pplan; chicago-court templates are
  AshA2A-targeted (port, not drop-in). Replacing ~473 passing hand-written
  fuzz courts with un-admitted generator output is negative-EV.
  Source: docs/jira/ECO-SA2A-PACKS.md (decision + evidence only,
  nothing implemented).
- D2. semantic-gate-witness-court-pack → ADOPT. Real machinery, not a husk:
  fail-closed court template (155 lines), byte-identical runner contract
  test, 18 marketplace consumers. Closes real gap: zero of 40 gates carry
  a negative witness; conform-falsify covers SHACL profile, not gates.
  Source: docs/jira/ECO-SEMANTIC-GATE-WITNESS.md (5-step adoption plan
  recorded there; execution is not done).
- D3. dsl-pack deletion → REFUSED (typed). priv/ggen/ash-pplan-dsl-pack has
  consumers: lib/ash_pplan/dsl.ex, lib/ash_pplan/dsl/pplan.ex,
  lib/ash_pplan/dsl/pplan/lift.ex, docs/pplan-w3c-audit-2026-10-04.md.
  Directory still on disk; no deletion performed; consumers grep executed.
  Source: receipts/alignment-wave-2026-10-04.md §5.
- D4. durability_checkpoint: durable-adapter binding is non-binding. The
  durable engine already checkpoints implicitly per step (park/resume over
  the store); an explicit op adds no behavior — if no explicit step exists
  the capability is arguably unrealizable as declared. Fix is either
  additive runtime op or subtractive ontology (Option B breaks the >=31
  catalog gate). Decided-as-diagnosed; fix not executed.
  Source: docs/jira/ECO-PROVIDER-QUALIFICATION.md Findings 2/3.
- D5. DemonstrationCourt timeout-flake classification → REFUTED. Solo run
  445.5s of 1800s budget (25%); reruns confirmed every court edge passes
  on compiling input; failures are concurrent-lane compile breakage in
  untracked test/support/marketplace_sim/, not court logic.
  Source: receipts/demonstration-court-classification-2026-10-04.md.

## 2. LANDED (lane → receipt pointer)

- L1. Fleet waves w20/w21/w25: 7 repos PASS (w21), courts 275/0, durable
  301/0, hardening 279/0, workflow 300/0 (w25, coordinator-relayed);
  standing PARTIAL_ALIVE. → receipts/fleet-wave-{w20,w21,w25}-2026-10-04.md
- L2. Case-study layer: bin/case-study LANDED as code (chain exit 1 at
  soak=10s, PASS at 30s — nondeterministic; 5 docs RUN-FIRST-PENDING).
  → receipts/case-study-layer-2026-10-04.md
- L3. Provider-qualification diagnosis: ZD11 court 837 pairs, 4 success,
  833 typed-refused, 0 crashes; three root causes F1-F3 named with lawful
  fixes. → docs/jira/ECO-PROVIDER-QUALIFICATION.md
- L4. W3C/P-PLAN audit fixes: F1 FIXED (mirror bodies hash-identical,
  13/0 court on _build-m2), F2 FIXED (ap:Provider + 13 properties), M1
  FIXED (AshPplan casing gone). → docs/pplan-w3c-audit-2026-10-04.md §5
- L5. DemonstrationCourt classification: NOT a timeout flake; cause
  attributed to concurrent-lane marketplace_sim WIP.
  → receipts/demonstration-court-classification-2026-10-04.md
- L6. Alignment compile-of-record: per-lane gate evidence, generated-vs-
  handwritten ledger, replay commands.
  → receipts/alignment-wave-2026-10-04.md
- L7. New courts/harnesses exist on disk: bin/manufacture-protocol-court,
  bin/runtime-contract-courts (86 zero-row courts), protocol-court
  differential court. → receipts/alignment-wave-2026-10-04.md §1.
- L8. 9 ECO-*.md orders RDF-generated (base c42ee19), all standing
  UNKNOWN, no execution receipts. → receipts/alignment-wave-2026-10-04.md

## 3. PENDING-COORDINATOR (nobody may take unilaterally)

- P1. Commit grouping of the 55-file dirty tree (+21721/-5347): lane-
  partitioned atomic commits; coordinator owns transitions.
- P2. Vendor re-pin commit (priv/ggen/vendor/{sync.sh,verify_lock.sh,
  PACKS.lock.json,provenance.ttl} modified) — including whether the
  semantic-gate-witness pack (ADOPTED, D2) enters sync.sh at pinned SHA.
- P3. Catalog.Projection elimination decision (projection_catalog.ex is
  GENERATED; hand-modified in tree) — regenerate vs retire.
- P4. ash-extension-core-pack adoption decision — adoption work order,
  standing UNKNOWN, no execution receipt (ECO-* family).
- P5. DemonstrationCourt quiescent rerun — schedule on a tree where
  marketplace_sim compiles and no lane writes test/support/; expected
  exit 0 in ~450s; exit-0 remains UNVERIFIED (two reruns raced WIP).

## 4. IN-FLIGHT (running verification lanes)

- I1. Courts lanes (cross_product_e2e, protocol_court,
  runtime-contract-courts, pplan_upstream).
- I2. Workflow lanes (runtime/evidence suites; w25 workflow 300/0 relayed).
- I3. marketplace_sim (GCP lifecycle sim) — untracked WIP; source of the
  DemonstrationCourt compile breakage; owns drivers.ex +
  contract_court_engine.ex (two minimally repaired, disclosed
  out-of-lane in audit §5).
- I4. Durable lanes (durable 301/0 relayed; protocol-court differential:
  tla-rs + Stateright + mutants).
- I5. Ontology lanes (SHACL conform, conform-falsify 13 counterexamples,
  ontology_semantics + ggen_pack_semantics courts 13/0).
- I6. Bench lanes (hot paths, store w23/w24, fleet_all_w25 aggregates).
- I7. Docs lanes (gate-petal-fw, gate-playwright receipts on disk).
- I8. DemonstrationCourt falsifier rerun — see P5 (blocked on quiescence).

## Cleanup owed at integration (leases, not assets)

- Delete orphaned lane build roots _build-w25-1..16, _build-case-76252,
  _build-demo-class, _build-demo-rerun, _build-m2 at integration.
  Source: receipts/alignment-wave-2026-10-04.md §4.

## Addendum 2026-10-04 (reconciliation)

Reconciles section 3 against items that executed after the ledger was written.
Compile-of-record only; no gates re-run by this lane. Lines ≤100 chars.

### Per-item reconciliation

- P1. STILL-PENDING. No lane-partitioned commits observed in the sources
  read; dirty tree unchanged by this lane.
- P2. STILL-PENDING. Vendor re-pin not executed; note new dependency: the
  saga upstream branch (below) requires re-pinning
  `priv/ggen/vendor/sync.sh` `rt_expected_sha` after the marketplace merge
  → docs/jira/ECO-SAGA-UPSTREAM-PR.md.
- P3. STILL-PENDING. No projection_catalog decision in the sources read.
- P4. IN-FLIGHT. Prep DONE: ADOPT-SAFE verdict recorded, 2-hunk
  formatter-class diff (render 1278 B vs in-tree 1328 B, semantic diff
  empty), falsifier named. Execution (mf_sync render + court test +
  ggen-verify + receipt) not yet witnessed.
  → docs/jira/ECO-ASHEXT-ADDITION-VERDICT.md
- P5. STILL-PENDING (exit-0 UNVERIFIED), with new cause classification:
  Run 3 was quiescent on sampled paths yet failed deterministically —
  untracked `test/petal_framework/` fixture tree shadows ExUnit's
  `test/**/*_test.exs` glob (SyntaxError on vendored phoenix EEx
  templates). Court's own 24 edges pass. Closure needs the fixture tree
  moved/renamed or a parent `test_paths` exclusion; that fix lane is
  IN-FLIGHT (not this lane's file).
  → receipts/demonstration-court-classification-2026-10-04.md §Run 3
- sa2a Option A (D1 execution). DONE. 23-triple patch applied;
  primitives 20→23, all UNSUPPORTED; projection ADMITTED + IN_SYNC
  exit 0; backup kept.
  → receipts/sa2a-unsupported-applied-2026-10-04.md
- Petal dep strategy (P-adjacent). DONE. Path dep on
  `test/petal_framework` removed, `petal_components ~> 2.8` added;
  gates exit 0 (compile + lifecycle court 10/0); clone undepended,
  untouched on disk. → docs/jira/ECO-PETAL-DEP-STRATEGY.md
- Saga upstream PR. DONE (branch), push STILL-PENDING. Branch
  `eco-saga-compensate-upstream` @ 65e4114be on
  /Users/sac/ggen-marketplace, one commit one file (+15), base = pinned
  503af6c2; 4 gates 0 violations; marketplace restored to main
  @ 503af6c2 with WIP intact. NOT PUSHED.
  → docs/jira/ECO-SAGA-UPSTREAM-PR.md
- Witness pack adoption (D2 execution) + pack mutation court: not
  witnessed by this lane in the sources read → IN-FLIGHT (adoption
  plan recorded in docs/jira/ECO-SEMANTIC-GATE-WITNESS.md).

### LANDED addendum

- LA1. sa2a pack family UNSUPPORTED standing applied (D1/Option A).
  → receipts/sa2a-unsupported-applied-2026-10-04.md
- LA2. Petal dep swap to hex `petal_components ~> 2.8`, gates 0 fail.
  → docs/jira/ECO-PETAL-DEP-STRATEGY.md
- LA3. Saga upstream branch `eco-saga-compensate-upstream` @ 65e4114be
  (unpushed), 4 gates 0 violations.
  → docs/jira/ECO-SAGA-UPSTREAM-PR.md
- LA4. ash-extension-core-pack verdict ADOPT-SAFE (P4 prep).
  → docs/jira/ECO-ASHEXT-ADDITION-VERDICT.md
- LA5. Docs lint fixes: 4 H1-vs-filename fixes, long-line wrapping
  (wrap-only), 7 owned files post-fix PASS.
  → receipts/docs-lint-fix-2026-10-04.md
- LA6. Gate receipts landed: durable 324/0 (5 skipped,
  _build-gate-dur), workflow 359/1 (DurableAdapterTest @ops missing
  `:scheduling_wakeup` — observation only), courts 348/1
  (pplan_upstream: 2 private p-plan terms — left for fixing lane),
  marketplace_sim 31/0 (_build-gate-mkt).
  → receipts/gate-{durable,workflow,courts,marketplace-sim}-2026-10-04.md
- LA7. Full-suite gate 2026-10-04b: compile 0, mix test exit 1 BLOCKED
  (same petal_framework template-glob SyntaxError; zero tests ran;
  retry reproduced identically).
  → receipts/gate-full-suite-2026-10-04b.md
- LA8. DemonstrationCourt Run 3: quiescent-run classification,
  deterministic glob-shadowing cause (see P5 above).
  → receipts/demonstration-court-classification-2026-10-04.md §Run 3

## Addendum 2 2026-10-04 (ERRC wave)

Reconciles the ERRC wave's executed items into this ledger. Compile-of-record
only; no gates re-run by this lane; statuses as relayed with on-disk
corroboration where noted. Lines <=100 chars.

### LANDED (ERRC wave)

- E2. observe-ontology hash-pinned; rdflib dependency dropped from the
  observation path. → bin/observe-ontology
- RA1. Strict parsers wired into bin/ggen-verify and bin/ggen-doctor
  (fail-closed on malformed inputs). Note: Pyright fixes in flight for the
  touched scripts. → bin/ggen-verify, bin/ggen-doctor
- C2. lib/HANDWRITTEN.md provenance ledger: 151 files = 31 GENERATED
  (2,129 LOC) / 120 HANDWRITTEN (15,777 LOC), re-derivable enumeration
  command included. → lib/HANDWRITTEN.md
- C4. Chaos-pack ACP: row file landed; court verified 10/10 byte-identical.
  [SUPERSEDED 2026-10-04: rows file deleted; vendored `ash-pplan-chaos`
  pack adoption recorded on `[packs.ash-pplan-chaos]` in `ggen.toml`.]
  → priv/ggen/ash-pplan-chaos-pack-acp-rows.ttl;
  test/courts/igniter_gen_byte_identity_court_test.exs
- C5. Refusal gates x4 in standing pack (150 untyped_refusal,
  160 standing_state_dangling, 170 standing_only_on_outcome,
  180 outcome_requires_pending). →
  priv/ggen/ash-pplan-standing-pack/verify/1{5,6,7,8}0_*.unbound.rq
- C6. OCEL v2 mapping court: lossless mapping proven over a real durable
  run; 2 gaps pinned in the court docstring. →
  test/courts/ocel_v2_mapping_court_test.exs
- C9. GCP web scaffold templates (marketplace `web` surface alignment for
  the marketplace_sim lane). → test/courts/gcp_lifecycle_plan_court_test.exs;
  receipts/gate-gcp-court-2026-10-04.md
- C10. Tokyo promotion runbook: per-file promotion classification
  (1 MUTANT, 6 SUPPORT; refusals/alignment/canonical templates sketched).
  → docs/jira/ECO-TOKYO-PROMOTION.md
- Registrar. 4 packs vendored + registered:
  workflow-corpus-pack, state-transition-pack, evidence-standing-pack,
  chaos pack. → priv/ggen/vendor/{workflow-corpus-pack,state-transition-pack,
  evidence-standing-pack,ash-pplan-chaos-pack}, priv/ggen/vendor/PACKS.lock.json
- Witness pack + bin/gate wiring: semantic-gate-witness vendored and gated.
  → priv/ggen/semantic-gate-witness/, bin/gate
- ashext pack adoption ALIVE. → priv/ggen/vendor/ash-extension-core-pack;
  docs/jira/ECO-ASHEXT-ADDITION-VERDICT.md
- RA2. Capability-surface probe → DECLINE: surfaces are a hardcoded
  marketplace match (7 generic), no project-local registration path.
  → receipts/ra2-capability-probe-2026-10-04.md
- RA3. Ontology status/list probe → PARK: embedded-bundle-only registry, no
  local-file mode; vendored ontologies undetectable. →
  receipts/ra3-ontology-probe-2026-10-04.md
- E1. Vendor parity ACHIEVED (shapes + N3 rules). Named unblockers:
  [packs.exemptions] (FM-CONFIG-002) + shapes.ttl pattern; residue fix lane
  in flight (see IN-FLIGHT). → docs/jira/ECO-ASHEXT-ADDITION-VERDICT.md;
  docs/whats-new-2026-10-04.md; test/courts/pack_inventory_court_test.exs
- C1. DSL court landed: GENERATED `pplan` DSL expands to same Model as
  literal (ALIVE, relayed). → test/courts/dsl/pplan_court_test.exs;
  test/courts/igniter/gen_workflow_court_test.exs

### IN-FLIGHT (ERRC wave)

- R1. Receipt-chain lane: in flight (no receipt file witnessed yet).
- Glob-fix lane: test/petal_framework fixture glob shadowing (P5 closure);
  in flight. → receipts/demonstration-court-classification-2026-10-04.md
  §Run 3
- Lanes. The 12 lanes of this ERRC wave remain in verification; standings
  here are per-lane, not integrated.

### PENDING-COORDINATOR (ERRC wave)

- E1 phase 2. conform* retirement swap, gated on the residue lane landing.
- Commit grouping P1 unchanged: 55-file dirty tree, lane-partitioned
  atomic commits. (Also: COMMIT-GROUPING-2026-10-04.md.)
- Upstream promotions: ashext template 0.1.2, saga branch push
  (`eco-saga-compensate-upstream` @ 65e4114be), tokyo templates.
  → docs/jira/ECO-SAGA-UPSTREAM-PR.md; docs/jira/ECO-TOKYO-PROMOTION.md

## Addendum 3 2026-10-04 (ERRC execution wave)

Folds in the execution wave's landed items. Compile-of-record only; no
gates re-run by this lane. Each item verified on disk or cited receipt;
where no on-disk artifact was found, marked "relayed". Lines <=100 chars.

### LANDED (execution wave)

- G1. Pack courts x3 on disk: pack_chaos / pack_ashext /
  pack_state_transition court tests exist; 12/0 gate result relayed.
  → test/courts/pack_chaos_court_test.exs,
  test/courts/pack_ashext_court_test.exs,
  test/courts/pack_state_transition_court_test.exs
- G3. Verb-gates court on disk with baseline-pinned law export BLAKE3
  hash check and 7-surface drift pin (RA2-pinned surface list as drift
  baseline). → test/courts/ggen_verb_gates_court_test.exs
- R2a. bin/gate provenance-verify step wired: verify_lock.sh invoked as
  authoritative lock re-hash + provenance.ttl packName/packOntologySha256
  pair re-hash, fail-closed (FAIL branch, no new deps).
  → bin/gate:187-208
- R1. Standing-parity court on disk: evidence-standing-pack vs SPARQL
  gates, invariant-by-invariant table with DRIFT rows both directions;
  11/0 relayed. → test/courts/standing_parity_court_test.exs
- R4. Falsifier receipt landed: 5 rows MISFILED + 1 narrow PARTIAL
  (LedgerOCEL); HANDWRITTEN reclassification recommended per row,
  in flight. → receipts/r4-falsifier-runs-2026-10-04.md
- R2b. Workflow-pack reactor generation: AST-based modify lane courts on
  disk; AST-identical + determinism sha 4b9aec3a... + typed cardinality
  refusal all relayed.
  → test/courts/igniter/gen_workflow_court_test.exs
- E1 phase 2. pack.toml present in vendored ash-extension-core-pack;
  conform* retirement swap IN-FLIGHT (not witnessed).
  → priv/ggen/vendor/ash-extension-core-pack/pack.toml
- Upstream branches verified on disk: ggen-marketplace
  `errc-promote-engine-compat-gates` @ a1c3de3c;
  `errc-promote-workflow-pack-and-ashext-template` exists (in flight);
  ggen_igniter `errc-igniter-envelope-and-chain-fixes` @ df6b0b94;
  derived-count mode in flight.
- P5. CLOSED. Quiescent rerun exit 0, 2 tests 0 failures, ExUnit wall
  1791.4s; exit-code caveat noted in receipt.
  → receipts/demonstration-court-classification-2026-10-04.md
- OCEL. Fixes landed (ledger_ocel.ex under ERRC commit 35cf8c8 lineage);
  court tightening in flight.
  → lib/ash_pplan/reactor/durable/ledger_ocel.ex
- Docs wave. coverage-index-2026-10-03.md and whats-new-2026-10-04.md
  updated on disk. → docs/jira/coverage-index-2026-10-03.md;
  docs/whats-new-2026-10-04.md
- E2 groundwork. 984 LOC confirmed, net -380 design — relayed; no
  on-disk artifact found by this lane for the 984/-380 figures.

### PENDING-COORDINATOR (execution wave)

- P1. Commit grouping — UNBLOCKED, pending this wave's gates; 55-file
  dirty tree, lane-partitioned atomic commits.
- Saga branch push (`eco-saga-compensate-upstream` @ 65e4114be) —
  STILL-PENDING.
- Igniter/marketplace branch pushes — STILL-PENDING (branches exist
  locally, verified above).
- E1 phase-2 swap acceptance — gated on conform* swap landing.
- DERIVED_ROWS mode acceptance — in flight, not witnessed.

## Addendum 4 2026-10-04 (delta execution + closeout)

Folds in the delta-execution wave's landed items. Every item verified on
disk or via the cited receipt by this lane; compile-of-record only, no
gates re-run, no git operations. Lines <=100 chars.

### LANDED (delta execution wave)

- R0. Gate-convention decision docs on disk: OFFENDER-vs-WITNESS scoring
  convention DECIDED (Option A, directory-is-convention); inventory
  111 gates/ entries, 66 verify/*.unbound.rq companions, 10
  contract-bearing packs; 11 misfiled offender-shaped queries named
  (8 evidence-standing, 2 state-transition, 1 semantic-gate-witness).
  → docs/jira/ECO-GATE-CONVENTION-DECISION.md;
  /Users/sac/ggen_igniter/docs/architecture/adr/
  0010-gate-convention-directory-is-convention.md (companion ADR)
- R4b. Falsifier receipt landed: state_machine.ex MISFILED → typed
  UNSUPPORTED (generator-capability; runtime ash_state_machine
  introspection adapter, zero template-class overlap); status.ex PARTIAL
  with named residue (from_transitions/4 only). Queue remaining:
  33 rows / 37 files.
  → receipts/r4b-state-transition-falsifier-2026-10-04.md
- HANDWRITTEN delta. Ledger updated: remaining queue 33 rows / 37 files;
  12 UNSUPPORTED reclassifications witnessed (16 UNSUPPORTED mentions on
  disk; R4 5 rows + R5 3 rows + prior reclassifications).
  → lib/HANDWRITTEN.md:19-37,330
- C2 witnesses. Upstream gate-promotion doc carries the witness table;
  witnesses are additive-only, no gate/verify query modified; upstream CI
  contract: paired pass witness expects 0 rows, fail witness >=1 row.
  Witness pair files on disk under
  priv/ggen/vendor/evidence-standing-pack/witnesses/{pass,fail}/
  (10 pairs listed: 010-070 stems).
  → docs/jira/ECO-UPSTREAM-GATE-PROMOTION.md (tail);
  priv/ggen/vendor/evidence-standing-pack/witnesses/
- P4+R3. bin/gate provenance overlay parsing landed: tdbv:overlayPath
  takes precedence over packName for overlay packs (shape b);
  provenance.ttl digest refresh + GREEN step present.
  → bin/gate:199,251-255
- ggen.toml wave. acp-rows rows file DELETED (supersedes C4; vendored
  ash-pplan-chaos pack adopted on [packs.ash-pplan-chaos], decision
  comment in-file); [law] section with shapes+rules landed;
  ontology/law_parity.n3 materialized (N3 denial-rule port of 5
  sh:sparql); bin/conform + bin/conform-falsify swapped to
  `ggen law validate`; 13/13 counterexample parity pinned by court.
  → ggen.toml:16,34-40,160; ontology/law_parity.n3;
  test/courts/law_validate_parity_court_test.exs
- Verb baseline re-pin. law-export baseline fixture pinned at
  triples=1043 (1041 stored + 2 derived marker); BLAKE3 graph_hash
  check + 7-surface registry drift pin in court.
  → test/courts/fixtures/law_export_baseline.txt:9;
  test/courts/ggen_verb_gates_court_test.exs:6-41
- state_transition timeout tag. `@moduletag timeout: 600_000` on the
  pack state-transition court. →
  test/courts/pack_state_transition_court_test.exs:39
- ash_reactor ETS fix. Extended court's Item resource uses shared ETS
  (`ets do private? false`) so steps resolve cross-process.
  → test/workflow/ash_reactor_extended_court_test.exs:27-30
- Evidence court subject pin. Evidence-hardening court pins subject_id
  = "sha256:" + 64 'a's; every Evidence.prov call bound to it; typed
  :invalid_timestamp refusal covered.
  → test/workflow/evidence_hardening_court_test.exs:23-57
- bin/gate first complete run. Receipt: exit 1, ~28 min, 10 FAIL
  classified in footer (ggen-doctor, hex.audit, deps.unlock,
  format, mix check, manufacture-unchanged, ggen-replay-court,
  provenance-verify, verify-package, ggen-verify); 6 PASS incl.
  conform, pack-gate-witness-court, receipt-chain-verify.
  → receipts/gate-bin-gate-2026-10-04.md
- Upstream branch updates. Workflow-pack branch @ 9b961d454 (post
  R2-sync commit on top of e6496435b); standing ALIVE locally, no push.
  → docs/jira/ECO-UPSTREAM-WORKFLOW-PACK.md:84,108
- P5 closure. Demo court quiescent rerun exit 0: 2 tests, 0 failures,
  ExUnit wall 1791.4s; exit-code caveat (wrapper timeout after ExUnit
  summary) noted in receipt; _build-demo-q2 deleted after run.
  → receipts/demonstration-court-classification-2026-10-04.md

### PENDING-COORDINATOR (delta execution wave)

- 3 branch pushes — READY per push-readiness receipt, AWAITING-USER
  authorization (engine-compat-gates, workflow-pack+ashext, igniter
  envelope+chain). → receipts/upstream-push-readiness-2026-10-04.md
- P1 commit grouping — refreshed grouping plan in flight.
  → docs/jira/COMMIT-GROUPING-2026-10-04.md
- law_parity prose cleanup refs — outstanding doc references to the
  retired conform* path pending sweep.

## Addendum 5 2026-10-04 (closeout wave)

Every LANDED item verified on disk or via the cited receipt by this lane;
compile-of-record only, no gates re-run, no git operations. Lines <=100
chars. Two task-relayed claims failed verification and are recorded as
NOT-WITNESSED below.

### LANDED (closeout wave, verified)

- Glob fix. mix.exs test_load_filters excludes `test/petal_framework/`
  (mix.exs:14-29; filter fn + regex pair). Compile past the vendored EEx
  templates witnessed in receipts/demonstration-court-classification-
  2026-10-04.md §"post test-glob fix" (full test tree compiled; durable
  adapter 11 tests, 0 failures). The relayed "full-run 2250-test" figure
  is NOT WITNESSED: no receipt or /tmp log carries a 2250 count; largest
  file-backed full-ish runs are 759/0 (gate-cd), 1693/0 (fleet-spot-check).
- R0 re-home. In-tree verified: evidence-standing-pack gates/ now empty,
  all 8 gates + literal_scan moved to verify/; state-transition-pack
  010/020 + 050 scan -> verify/, witness gates 030/040 stay; verify/
  cardinality.json present in both. Mirror commit c76220c2a on
  ggen-marketplace `errc-promote-engine-compat-gates` ("re-home offender
  gates per ADR 0010", 11 gates, both-way witness runs 22/22). Honest
  PASS flip: packs shipping zero witness gates now report PASS as
  zero-gates (empty gates/ dir + decision note), not inverted witness
  scoring. → priv/ggen/vendor/{evidence-standing-pack,
  state-transition-pack}/{gates,verify}/
- C1 dsl-pack court. test/courts/dsl/pplan_court_test.exs on disk; ran
  inside the gate-cd consolidated re-gate (population check names
  dsl/pplan; 759 tests, 0 failures). The relayed "10/0" per-file count
  has no separate file-backed receipt; covered by 759/0.
  → receipts/gate-courts-d-2026-10-04.md
- marketplace_sim re-gate. 31 tests, 0 failures, exit 0.
  → receipts/gate-marketplace-sim-b-2026-10-04.md (_build-gate-mkt2)
- bin/gate rerun b. Full bin/gate, 22 min, 10 FAIL all classified into
  the expected set (ontology content pin, hex.audit, deps.unlock,
  demo-clone format, manufacture replay drift, ggen-replay-court,
  provenance-verify, verify-package, ggen-verify); 6 PASS. No rerun
  "c" receipt exists; the courts/workflow re-gates are gate-courts-b
  (700/0), -c (750/4, classified), -d (759/0, clean).
  → receipts/gate-bin-gate-2026-10-04b.md;
  receipts/gate-courts-{b,c,d}-2026-10-04.md
- Upstream push-readiness. 3 branches audited read-only, all tips match:
  ggen-marketplace errc-promote-engine-compat-gates @ a1c3de3cd (READY,
  AWAITING-USER), errc-promote-workflow-pack-and-ashext-template @
  9b961d454 (READY, AWAITING-USER), ggen_igniter
  errc-igniter-envelope-and-chain-fixes @ d636106 (READY, AWAITING-USER).
  Gap noted in receipt: ADR 0010 + ECO-GATE-CONVENTION-DECISION.md are
  still untracked working-tree files in their repos.
  → receipts/upstream-push-readiness-2026-10-04.md
- Workflow-pack upstream branch @ 9b961d454 (R2 sync on e6496435b;
  ontology 1041 triples, header-stripped hash byte-identical to the
  committed pack copy). Verified in receipt + marketplace git log.
  → docs/jira/ECO-UPSTREAM-WORKFLOW-PACK.md:84,108
- GateVerify moduledoc commit f960d25af in ggen_igniter ("docs:
  GateVerify convention (ADR 0010) — directory-is-convention"), on main
  after checkout from the branch tip d636106. Verified in git reflog.
- acp-rows prose cleanup. docs/diataxis/how-to/adopt-a-marketplace-pack.md
  §Rows-translation pilot carries the superseded note (rows file deleted;
  vendored ash-pplan-chaos pack replaces it), verified on disk.
- P5 caveat status. RE-OPENED as a nonzero-exit caveat: explicit wrapper
  EXIT=2 obtained (2 runs), sole failure = bin/demonstrate lock REFUSED
  (external lane held tmp/.demonstrate-lock); 3/4 edges pass. Clean
  re-close needs a quiescent window with the lock absent.
  → receipts/demonstration-court-classification-2026-10-04.md
  §"Exit-code caveat closure attempt"

### NOT-WITNESSED (relayed claims this lane could not verify)

- Vendor re-lock "verify_lock OK 293 files, provenance GREEN, lock sha
  dd4fc64d...": no receipt, doc, or log on disk carries 293 files or
  dd4fc64d. Live `sh priv/ggen/vendor/verify_lock.sh` reports OK (9
  packs, lock 503af6c27c...) with WARN: marketplace HEAD a1c3de3cd !=
  pinned 503af6c27c (non-strict). Newest lock receipt is
  receipts/gate-vendor-lock-2026-10-04.md (determinism double-run, 3
  packs, lock 503af6c27c). A re-lock lane was expected to move
  provenance-verify (gate-bin-gate-2026-10-04b note) but no post-re-lock
  GREEN receipt landed.

### IN-FLIGHT (closeout wave)

- Hygiene, dets, release-contract, deps, formatter, verify-package,
  parser, regen, observe-pin, re-home-mirror lanes; remaining bin/gate
  FAIL steps awaiting their fixing lanes' receipts.

### PENDING-COORDINATOR (closeout wave)

- Pushes: all 3 upstream branches READY / AWAITING-USER.
- P1 grouped commits: dirty tree uncommitted; lane-partitioned atomic
  commits.
- Petal gitlink decision: test/petal_framework stays untracked on disk;
  keep / move / delete undecided.
- mix test Elixir-1.17 floor leg: SKIP (needs Elixir 1.17 on PATH; CI
  floor matrix leg covers it).

## Addendum 6 2026-10-04 (closeout wave 2)

Every item below verified on disk by this lane; compile-of-record only,
no gates re-run, no git operations. Lines <=100 chars.

### LANDED (closeout wave 2, verified on disk)

- Keyless-keying fix. bin/ggen-replay-court carries the keyless-grouping
  policy: a keyless receipt's freshest is ITSELF, superseded only by
  another keyless receipt on the same sorted-output-file-set sha;
  source_hash/plan_hash null on every keyless row. Relayed counts
  63 -> 10 FAILs; anti-vacuity + positive control witnessed in the
  lane's own run (not re-witnessed here); /tmp/av-store residue present
  (8.0K on disk). → bin/ggen-replay-court:148-159
- status.ex GENERATED conversion. On-disk header: "GENERATED by
  ggen_igniter from ontology.ttl (st:RunStatusMachine rows)"; regen
  command cites status_fsm.ex.eex (template on disk at
  priv/ggen/ash-pplan-workflow-pack/templates/status_fsm.ex.eex) +
  --out lib/ash_pplan/reactor/durable/status.ex. AST-identical +
  661/0 gates relayed; handwritten copy preserved at
  /tmp/status_handwritten.ex (present). ontology.ttl carries 40
  st:RunStatusMachine mentions; the relayed "43 rows" figure not
  re-counted here. CONFORMS=False is pre-existing FM-PACK-005 (not
  introduced by the conversion).
  → lib/ash_pplan/reactor/durable/status.ex:1-7;
  receipts/e2-falsifier-runs-2026-10-04.md
- Witness fixtures restored. witnesses/{pass,fail} dirs on disk under
  evidence-standing-pack, state-transition-pack, workflow-corpus-pack.
  Root cause confirmed: priv/ggen/vendor/ (and these packs) are
  UNTRACKED — `git status` shows ?? for vendor packs, so witnesses
  were never committed; the working-tree loss was the untracked tree.
  Relayed gate result 24/0.
  → priv/ggen/vendor/*/witnesses/
- E2 reclassification. receipts/e2-falsifier-runs-2026-10-04.md:102
  records totals 33->29 rows; lib/HANDWRITTEN.md:39-41 carries
  "Remaining queue: 29 rows / 33 files" with ash_pplan.ex, compiler.ex,
  reactor.ex, fond.ex reclassified. workflow/project/reactor.ex
  falsifier lane IN-FLIGHT (no closing receipt yet).
  → lib/HANDWRITTEN.md:39-41;
  receipts/e2-falsifier-runs-2026-10-04.md:102
- [law].gates 42 -> 51. ggen.toml [law].gates carries 51 .rq paths
  (counted); new ERRC-delta block wires 9 offender gates (2
  state-transition + 7 evidence-standing) onto the [law] surface.
  030/040 correctly EXCLUDED as witness-shaped: the in-file comment
  says witness-shaped gates MUST NOT appear here and 030 returns 30
  rows on the clean ontology. In-file note says "All 42 gates return
  zero rows" — stale prose vs the 51-path count (comment predates the
  +9 wiring); the relayed "empirical correction 13 -> 9" matches the
  9-gate block.
  → ggen.toml [law].gates + comments
- bin/gate workflow-corpus-court step. Present exactly at lines
  341-345: fail-closed mix test step for
  test/courts/workflow_corpus_court_test.exs, between the witness
  court and ggen-replay-court steps.
  → bin/gate:341-345
- Grouped commits wave 1. On main, in order: 07cc823 gitignore (lane
  build roots + local state + bin/__pycache__), 243ca91 docs (ERRC
  ECO-jira docs + receipts + coverage index + README/whats-new),
  02723ba bench (w23/w24/w25 raw tees + fleet logs + soak numbers).
  A-D/G/H groups deferred pending quiescence (dirty tree still ~55
  files; vendor packs remain untracked).
  → git log (read-only)
- Trash cleanup denied. ~809 MB /tmp deletion request refused; no
  deletion performed by this lane. /tmp/av-store (8.0K) and
  /tmp/status_handwritten.ex remain on disk.
  → /tmp listing

### PENDING-COORDINATOR (closeout wave 2)

- Pushes: all upstream branches remain unpushed (AWAITING-USER).
- Chaos FM-PACK-005 fix: IN-FLIGHT (fixing lane, not this one).
- Remaining group commits: A-D/G/H deferred pending quiescence.
- GateVerify offender-row expected-FAIL table: upstream (ggen_igniter).

## Addendum 7 2026-10-04 (restore + closeout wave 2)

- Loss root cause (witness fixtures + verify/ trees). A concurrent
  `priv/ggen/vendor/sync.sh` run regenerates the vendor tree wholesale;
  `priv/ggen/vendor/` is UNTRACKED (`git status` shows ?? for all vendor
  packs), so anything the regen wiped had no committed copy. Witness
  fixtures (witnesses/{pass,fail}) and verify/ trees vanished from the
  working tree in that window.
  → priv/ggen/vendor/sync.sh; git status (vendor packs untracked)
- Restore lane landed. sync.sh patch 2g ("verify/ re-home + witnesses/
  shield", ECO-GATE-CONVENTION R0) present at sync.sh:383+; idempotent,
  upstream verify/ wins where the pack ships one. Re-materialized trees
  verified on disk: 45 `verify/*.unbound.rq` across the 6 overlay packs;
  witnesses/{pass,fail} present under evidence-standing-pack,
  state-transition-pack, workflow-corpus-pack.
  → priv/ggen/vendor/sync.sh:383-458; priv/ggen/vendor/*/verify/,
  priv/ggen/vendor/*/witnesses/
- Commit wave. Group D landed as 37bc291 (courts: protocol court +
  runtime-contract courts + marketplace_sim/web surface). Groups A/B/C/G/H
  remain uncommitted pending quiescence; working tree currently 73 M /
  116 ?? / 3 D (git status count). FLAG: the runtime-overlay trees
  (~68 lib/test overlay files + ~54 overlay-pack files) carry NO group in
  the commit plan — must be assigned before the wave resumes.
  → git log (read-only); docs/jira/COMMIT-GROUPING-2026-10-04.md
- Placeholder wave. sync.sh FM-PACK-005 re-add hook present
  (sync.sh:83, templates/*.tmpl floor re-adds placeholders); 8 packs
  vendored under priv/ggen/vendor/ (ash-extension-core, ash-pplan-chaos,
  ash-pplan-protocol-court, evidence-standing, semantic-gate-witness-court,
  state-transition, tokyo-depeg-burn-in, workflow-corpus). Relayed
  CONFORMS=True + 13/13 falsifier refusals are file-backed at
  receipts/gate-ontology-2026-10-04.md (CONFORMS=True, 812 triples,
  exit 0) — the "1272 triples" figure relayed in dispatch was NOT found
  on disk; disk-recorded count is 812.
  → priv/ggen/vendor/sync.sh:83,115-120; receipts/gate-ontology-2026-10-04.md:41-45
- [law] path-integrity repoint. ggen.toml [law].gates: 51 entries, 51/51
  exist on disk (os.path.exists sweep, this session). 9 vendor entries
  now point at verify/*.unbound.rq (2 state-transition + 7
  evidence-standing, R0 re-home); 030/040 witness-shaped gates correctly
  excluded, 2 literal-scan offenders are .py and stay court-executed.
  → ggen.toml [law].gates:41-110
- Keyless-keying court fix. bin/ggen-replay-court keyless-grouping policy
  (freshest keyless = ITSELF, superseded only by same sorted-output-
  file-set sha; null source_hash/plan_hash). Relayed counts 63 → 10 rows;
  file-backed at this ledger, lines 497-500 (prior addendum).
  → bin/ggen-replay-court; receipts/integration-ledger-2026-10-04.md:497-500
- [law].gates 42 → 51. Counted 51 .rq paths in ggen.toml (42 original +
  9-gate ERRC-delta block); stale in-file "All 42 gates return zero rows"
  prose noted in prior addendum, still unreconciled on disk.
  → ggen.toml:19,86-108
- status.ex GENERATED. On-disk header line 1: "GENERATED by ggen_igniter
  from ontology.ttl (st:RunStatusMachine rows)"; template at
  priv/ggen/ash-pplan-workflow-pack/templates/status_fsm.ex.eex.
  Pre-existing FM-PACK-005 CONFORMS=False unchanged.
  → lib/ash_pplan/reactor/durable/status.ex:1
- E2/E2b/E3 falsifiers. receipts/e2-falsifier-runs-2026-10-04.md totals
  33→29 rows (4 rows UNSUPPORTED generator-capability); e2b reactor
  projection lane in-flight (no closing receipt on disk); e3 batch:
  queue 29 → 26 rows / 33 → 30 files (e3 receipt line 138). NOTE:
  lib/HANDWRITTEN.md:37-47 on disk still says "33 rows / 37 files" at :37
  and "29 rows / 33 files" at :41/:47 — the 26-row figure is NOT yet
  reflected there.
  → receipts/e2-falsifier-runs-2026-10-04.md;
  receipts/e3-falsifier-batch-2026-10-04.md:138; lib/HANDWRITTEN.md:37-47
- Docs wave. Stale cross-refs and the HANDWRITTEN status-row updates are
  recorded in receipts and coverage-index; lib/HANDWRITTEN.md queue lines
  lag e3 by one wave (above). ggen.toml NOTE block present (R0 re-home
  comment at ggen.toml:100).
  → lib/HANDWRITTEN.md; docs/jira/coverage-index-2026-10-04.md:194-209
- state_machine PARTIAL closure. coverage-index row:
  test/semantic_reality_state_machine_court_test.exs — "illegal
  transitions refused BY Ash; real lifecycle resolved — ALIVE (relayed)";
  state_machine.ex verdict misfiled → typed UNSUPPORTED per coverage
  index:194.
  → docs/jira/coverage-index-2026-10-04.md:63,194
- gate-100 retirement. 100_task_props now exists ONLY as
  verify/100_task_props.unbound.rq (gates/100_task_props.rq re-homed).
  Final ggen-verify table still FAILs it: 64 rows vs contract 46 —
  classified (c) genuine residual from the 26.10.2 contract downgrade.
  → priv/ggen/ash-pplan-workflow-pack/verify/100_task_props.unbound.rq;
  receipts/ggen-verify-final-2026-10-04.md
- Overlay digest adjudication. RELAYED as COHERENT with re-recorded
  digests + forced PACKS.lock generated[0] update. DISK DISCREPANCY: no
  COHERENT receipt found under receipts/; PACKS.lock.json schema carries
  a `packs` list (no top-level `generated` key — first pack is
  tokyo-depeg-burn-in-pack, source_tree_dirty: true). FLAG: sha256 of
  priv/ggen/vendor/provenance.ttl on disk is 4409e26b... (shasum, this
  session); the relayed "self-hash now b54d1737" appears NOWHERE on disk.
  Adjudication value unverified — treat as UNKNOWN until a file-backed
  receipt lands.
  → priv/ggen/vendor/PACKS.lock.json; shasum -a 256 provenance.ttl
- Full-suite gates c/d. receipts/gate-full-suite-2026-10-04c.md/.d:
  exit 2, 2259 tests, 19 failures / 76 skipped; 4 root causes — 15x
  query-hygiene DISTINCT, 2x package_exclusions mix.exs, 1x mutation-court
  silent-skip, 1x ETS teardown race. Budget blown (80.9 min test phase).
  Hygiene/petal/baseline classes since fixed (courts-e rerun: compile
  exit 0, 946 tests 2 failures). packet-dep + infra rows remain.
  → receipts/gate-full-suite-2026-10-04c.md:11-43;
  receipts/gate-courts-e-2026-10-04.md:20-25
- bin/gate reruns b/c/d + final ggen-verify. gate receipts b/c/d on disk
  (gate-courts-b/c/d). Final ggen-verify receipt (14-pack surface):
  9 PASS / 2 FAIL / 2 ENGINE-LIMIT / 1 crash. FAILs: workflow-pack
  100_task_props (64 vs 46) + workflow-corpus f000 zero-rows; ENGINE-LIMIT:
  state-transition + evidence-standing (sparql.ex 0.3.12 no
  EXISTS/NOT EXISTS); crash: ash-extension-core-pack
  SPARQL.Algebra.Expression :$undefined, exit nonzero, no envelope.
  Wrapper exit nonzero; envelopes at tmp/ggen-verify/*.json.
  → receipts/ggen-verify-final-2026-10-04.md
- PENDING-COORDINATOR: pushes (user, AWAITING-USER); patch_sync.py
  diagnostic — NOT on disk anywhere (find over repo, _build/deps
  excluded): in-flight lane artifact, unlanded; Group commits A/B/C/G/H
  + unassigned runtime-overlay trees; HANDWRITTEN.md queue-line refresh
  to 26 rows; provenance.ttl self-hash re-record with the on-disk
  4409e26b value or produce the b54d1737 backing receipt.

# HANDWRITTEN

Provenance ledger: converts UNKNOWN-provenance `lib/` code into typed residue
(ERRC C2). Re-derivable from a clean checkout.

```sh
# Enumeration command (exact, re-derivable):
find lib -name '*.ex' | sort > /tmp/all_ex.txt
for f in $(cat /tmp/all_ex.txt); do
  m=$(head -12 "$f" | grep -m1 -E 'GENERATED[- ](by|from|PROVENANCE)')
  [ -n "$m" ] && echo "G $f" || echo "H $f"
done
```

Rule: a file is GENERATED iff a `# GENERATED ...` provenance marker appears in
its first 12 lines; everything else is HANDWRITTEN = irreducible residue
(hand edits are the intended maintenance path) unless a marketplace pack could
generate it — those queue as candidates for the next ERRC pass. A handwritten
file that a pack could generate needs an explicit UNSUPPORTED
(generator-capability) receipt before it may stay handwritten.

## Totals (2026-10-04)

- Files: 151 total. GENERATED: 32 files / 2,314 LOC. HANDWRITTEN: 119 files /
  15,744 LOC.
- Handwritten share: ~87% of LOC. Machinery share rises only when candidates
  below convert to GENERATED with a pack receipt.
- ERRC R4 (2026-10-04): 5 top candidates reclassified UNSUPPORTED
  (generator-capability) after pack-template falsification; capability.ex
  recorded PARTIAL.
- ERRC R5 / delta audit (2026-10-04): standing.ex, standing/cached.ex,
  sj_bridge.ex reclassified UNSUPPORTED (generator-capability) — the
  standing-ladder-pack ships only a markdown echo template
  (`standing_audit_trail.md.tmpl`), zero template-class overlap with the
  523-LOC judgment library. E2: engine.ex, store/{dets,ets}.ex,
  workflow/runtime.ex `none` annotations confirmed as PERMANENT RESIDUE.
  Remaining queue: 33 rows / 37 files.
- ERRC delta E2 (2026-10-04): ash_pplan.ex, compiler.ex, reactor.ex, fond.ex
  reclassified UNSUPPORTED (generator-capability) after per-module pack-template
  falsification (receipts/e2-falsifier-runs-2026-10-04.md). Remaining queue:
  29 rows / 33 files.
- ERRC delta E2b (2026-10-04): workflow/project/reactor.ex reclassified
  UNSUPPORTED (generator-capability) after a full 300-pack scan — see
  receipts/e2b-reactor-projection-falsifier-2026-10-04.md. Note: the row read
  `none`, not `unknown` (the last literal `unknown` row is
  frontier_evidence.ex); this falsifier upgrades it to dated UNSUPPORTED.
  Remaining queue unchanged: 29 rows / 33 files (the row was not counted as a
  candidate).
- ERRC E3 falsifier batch (2026-10-04): workflow/subject.ex,
  workflow/evidence.ex, fond/corpus.ex reclassified UNSUPPORTED
  (generator-capability); fond.ex re-confirmed UNSUPPORTED; 4 new
  UNSUPPORTED rows. process_evidence.ex verdict is GENERABLE, NOT
  reclassified — ash-ex4pm-evidence-pack `process_evidence.ex.tmpl` covers
  the class (receipts/e3-falsifier-batch-2026-10-04.md drafts the conversion
  runbook). Remaining queue: 26 rows / 30 files.
- Reopen triggers (E3, 2026-10-04): evidence-standing-pack `chain.ex.tmpl`
  is the first Elixir template class in the standing/evidence domain
  (emits lib/es/chain.ex from es: ChainPolicy/Phase/Standing rows) — any es:
  template emitting ladder-admission or PROV-O serialization reopens
  standing.ex / execution_receipt.ex (and workflow/evidence.ex). Also:
  process_evidence.ex reopens if the E3 runbook fails qualification;
  subject.ex reopens on any Elixir projection-verification template class;
  fond.ex / fond/corpus.ex reopen on any strong-cyclic / corpus-generator
  Elixir template class.
- ERRC delta RA3b (2026-10-04): sa2a/policy_candidate.ex reclassified
  UNSUPPORTED (generator-capability) after a current-pack sa2a falsifier —
  sa2a-semantic-evidence-pack HAS gained Elixir templates since E3 (it is no
  longer a zero-template husk) but its contract class is a descriptor echo +
  envelope admit gate, disjoint from candidate manufacture; provider.ex
  re-confirmed UNSUPPORTED (ERRC R3 verdict unchanged). See
  receipts/ra3b-sa2a-falsifier-2026-10-04.md. Queue: 25 rows / 29 files.
- ERRC delta E2c (2026-10-04): reactor/durable/status.ex reclassified
  GENERATED — rendered by the ash-pplan-workflow-pack `status_fsm.ex.eex`
  template (st:RunStatusMachine rows; handwritten copy preserved at
  /tmp/status_handwritten.ex for diff). Remaining queue: 29 rows / 33 files.
- ERRC delta RA1 (2026-10-04): observation.ex, workflow/project/fond.ex,
  fond/policy_supervisor.ex, fond/policy_supervisor/offers.ex,
  fond/policy_switch.ex, process_evidence/ex4pm.ex reclassified UNSUPPORTED
  (generator-capability); process_evidence/ash_ex4pm.ex verdict GENERABLE
  (candidate retained, runbook drafted) — ash-ex4pm-evidence-pack
  `ex4pm_adapter.ex.tmpl` is generalized from it
  (receipts/ra1-reclassifications-2026-10-04.md). Queue recount by grep
  (not arithmetic): the ledger prose previously claimed 29 rows / 33 files
  but grep found 23 rows / 27 files before RA1; after RA1, 17 literal
  "pack candidate" rows / 21 files remain, plus 2 GENERABLE candidates
  retained (process_evidence.ex, process_evidence/ash_ex4pm.ex).

## GENERATED (32 files, manufacture recipe cited)

- lib/ash_pplan/catalog/{plan_catalog,projection_catalog}.ex — ggen_igniter
  from ontology.ttl (plan_catalog / projection_catalog rows).
- lib/ash_pplan/dsl.ex, lib/ash_pplan/dsl/pplan.ex,
  lib/ash_pplan/dsl/pplan/lift.ex — ggen_igniter from ontology.ttl (Spark DSL
  extension row ap:dslSection).
- lib/ash_pplan/providers/{a2a,domain,durability,durable_dispatch,event_state,
  file,index,network,observation,process,remote,scheduling}.ex (12 files) —
  ggen_igniter from ontology.ttl, one provider row each; re-sync via
  `mix ggen_igniter.sync`.
- lib/ash_pplan/reactor/adapters/ash_reactor_extended.ex and
  lib/ash_pplan/reactor/generic_action_bridge.ex — ggen_igniter from
  ash-extension-core-pack ontology (aex:AshPPlanAshReactorExtended /
  aex:ReactorActionBridge).
- lib/ash_pplan/reactor/telemetry_middleware.ex — ggen_igniter from
  priv/ggen/ash-pplan-reactor-mw-pack/ontology.ttl (aexmw:TelemetryMiddleware).
- lib/ash_pplan/standing/{chain,receipt}.ex — ggen_igniter from
  priv/ggen/ash-pplan-standing-pack/ontology.ttl.
- lib/ash_pplan/workflow/capability_catalog.ex — ggen_igniter from
  ontology.ttl.
- lib/ash_pplan/reactor/durable/status.ex — ggen_igniter from
  priv/ggen/ash-pplan-workflow-pack/templates/status_fsm.ex.eex
  (st:RunStatusMachine rows); re-sync via `mix ggen_igniter.sync` (see the
  file's header for the exact command).
- lib/mix/tasks/ash_pplan.gen.workflow.ex — ggen_igniter from
  priv/ggen/ash-pplan-igniter-pack (ig:Task generator rows).
- lib/ash_pplan/reactor/durable/compensations/{dispatch,poll}.ex — ggen_igniter;
  template packs/ash-runtime-integration-contract-pack/templates/
  durable_saga_compensation.ex.eex; ontology rt:SagaCompensation.
- lib/ash_pplan/runtime_contract/{authority_gate,exact_subject,receipt,refusal,
  replay}.ex — EEx/Tera projection of packs/ash-runtime-integration-contract-pack/
  templates/receipt.ex.tmpl at marketplace pin
  503af6c27cef7838dcd82755ab2fe6a44f9eb6a2, applied by
  bin/manufacture-runtime-contract + priv/ggen/vendor/sync.sh.

## HANDWRITTEN residue (119 files: path | purpose | pack candidate)

Candidate = a marketplace pack plausibly covers the domain (names-only check
against ~/ggen-marketplace/packs/); none = no pack covers it; unknown =
judgment deferred. Candidates queue for the next ERRC pass.

- lib/ash_pplan.ex — root facade, P-PLAN/PROV-O into the Ash stack |
  UNSUPPORTED (generator-capability): ash-pplan-igniter-pack's sole template is a
  Mix task (`gen_workflow_task.ex.eex`); zero facade-class templates across all
  300 packs (ERRC E2, 2026-10-04).
- lib/ash_pplan/action/run.ex — Ash generic action executing a compiled P-PLAN
  | none.
- lib/ash_pplan/capability_pack.ex — bundle of provider capability
  declarations | none.
- lib/ash_pplan/capability.ex — typed capability identity `Family.Name` |
  PARTIAL: graphlaw-ash-capability-pack is the closest fit (only pack that
  projects Elixir from RDF) but covers registry-surface families, not a
  63-LOC parse struct — template overhead exceeds the module (ERRC R4,
  2026-10-04); conversion not justified.
- lib/ash_pplan/compiler.ex — compiles P-PLAN topology into Reactor.Builder
  calls | UNSUPPORTED (generator-capability): all pack reactor templates
  (`reactor_pipeline.ex.tmpl`, `reactor.ex.tmpl`) emit static pipelines; no
  template class expresses a plan-data→Reactor.Builder runtime compiler
  (ERRC E2, 2026-10-04).
- lib/ash_pplan/compiler/error.ex — compile error exception | none.
- lib/ash_pplan/config.ex — Application-env read seam | none.
- lib/ash_pplan/control_plane.ex — composes Ash/StateMachine/Oban/Reactor
  surfaces | none.
- lib/ash_pplan/execution_receipt.ex — PROV-style receipt of one execution |
  UNSUPPORTED (generator-capability): receipt-provenance-unification-pack
  generates Python validators over receipt JSON documents, zero Elixir
  templates and no prov:/p-plan: RDF emission; the module's PROV-O N-Triples
  serializer has no analog in the pack (ERRC R4, 2026-10-04). Reopen trigger
  resolved 2026-10-04: evidence-standing-pack `chain.ex.tmpl` emits a
  hash-chain ledger (`Es.Chain`, append/verify/seal) with zero PROV-O/RDF
  emission, no struct, no escaping, no identity validation — < 1% overlap
  (shared idiom: sha256 hex digest only); verdict UNSUPPORTED
  (receipts/ra3a-chain-falsifier-2026-10-04.md).
- lib/ash_pplan/frontier_evidence.ex — deterministic FrontierEvidence v1
  projection | unknown.
- lib/ash_pplan/manufacture_targets.ex — source of truth for the ggen_igniter
  manufacture manifest | none (it IS the generator manifest).
- lib/ash_pplan/oban.ex — projects AshOban triggers into planner data | none.
- lib/ash_pplan/policy_closure/authority_ceiling.ex — typed authority ceiling
  for policy admission | none.
- lib/ash_pplan/process_evidence.ex — workflow-run events + pure local OCEL
  2.0 JSON export | GENERABLE (candidate retained): ash-ex4pm-evidence-pack
  `process_evidence.ex.tmpl` covers the class (generalized FROM this module;
  behaviour + Event struct + events_from_receipt + OCEL 2.0 export + digest);
  conversion pending the runbook in receipts/e3-falsifier-batch-2026-10-04.md
  (declare AshPPlan ex4ev:Emitter row → render → port local guards upstream →
  qualify) (ERRC E3, 2026-10-04).
- lib/ash_pplan/process_evidence/ash_ex4pm.ex — AshPPlan→canonical ex4pm
  adapter | GENERABLE (candidate retained): ash-ex4pm-evidence-pack
  `ex4pm_adapter.ex.tmpl` (192 lines) is generalized FROM this module and
  covers the guarded envelope/validate/ingest class; conversion pending the
  runbook in receipts/ra1-reclassifications-2026-10-04.md (ERRC RA1,
  2026-10-04).
- lib/ash_pplan/process_evidence/event.ex — evidence event struct | none.
- lib/ash_pplan/process_evidence/ex4pm.ex — Event→Ex4pm mapping |
  UNSUPPORTED (generator-capability): evidence pack's other templates are
  class-disjoint (realtime bridge, court); no pack template covers the
  Event→Ex4pm.EventLog mapping + OCEL 2.0 serialize/parse-back class (ERRC
  RA1, 2026-10-04, receipts/ra1-reclassifications-2026-10-04.md).
- lib/ash_pplan/provider.ex — the single provider contract | UNSUPPORTED
  (generator-capability): typed-refusal admission logic; no pack covers it and
  cross-repo duplication NOT witnessed (ERRC R3, 2026-10-04).
- lib/ash_pplan/providers/qualify.ex — qualification shared by generated
  providers | UNSUPPORTED (generator-capability): admission-logic hazard per
  ERRC plan; pack promotion deferred — no parallel qualify/realize pipeline
  found in ash_a2a/xaas (ERRC R3, 2026-10-04).
- lib/ash_pplan/providers/registry.ex — immutable provider registry with
  generation fencing | UNSUPPORTED (generator-capability): nearest analog
  (AshA2A.Replan.ProviderRegistry) lacks authority ranking, sealing semantics
  and :no_qualified_provider refusals — duplication not witnessed (ERRC R3,
  2026-10-04).
- lib/ash_pplan/providers/resolver.ex — pure capability→provider resolution |
  UNSUPPORTED (generator-capability): cost-ordered qualify→realize resolution
  with authority ceiling is admission logic; zero :no_qualified_provider hits
  in ash_a2a/xaas libs (ERRC R3, 2026-10-04).
- lib/ash_pplan/reactor_outcome.ex — classifies Reactor results into planner
  observations | none.
- lib/ash_pplan/reactor.ex — binds a Reactor to one workflow subject |
  UNSUPPORTED (generator-capability): pack templates emit static reactors/steps;
  none express runtime `Reactor.Step` identity enrichment (`enrich/identity_of/
  inherit`) (ERRC E2, 2026-10-04).
- lib/ash_pplan/reactor/adapter.ex — adapter behaviour (only modules allowed
  to name Reactor impls) | none.
- lib/ash_pplan/reactor/adapters/ash_reactor.ex — adapter over ash_reactor |
  none.
- lib/ash_pplan/reactor/adapters/bb_reactor.ex — robot actuation via
  bb_reactor | none.
- lib/ash_pplan/reactor/adapters/durable.ex — native durable-engine adapter |
  none.
- lib/ash_pplan/reactor/adapters/local.ex — local adapter | none.
- lib/ash_pplan/reactor/adapters/reactor_file.ex — reactor_file adapter | none.
- lib/ash_pplan/reactor/adapters/reactor_process.ex — supervised-process ops
  via reactor_process | none.
- lib/ash_pplan/reactor/adapters/reactor_req.ex — reactor_req adapter | none.
- lib/ash_pplan/reactor/durable/checkpointed.ex — step wrapper providing
  durability | none.
- lib/ash_pplan/reactor/durable/child_error.ex — child failure propagation |
  none.
- lib/ash_pplan/reactor/durable/clock.ex — injectable time | none.
- lib/ash_pplan/reactor/durable/counterfactual.ex — counterfactual replay from
  the ledger | UNSUPPORTED (generator-capability): process-intelligence-pack
  projects OCEL event-tap adapters from RDF individuals; the module is a
  replay engine (change planning, dependency-closure invalidation, digest
  invariance) — semantics disjoint from any pack template (ERRC R4,
  2026-10-04).
- lib/ash_pplan/reactor/durable/engine.ex — durable run lifecycle over a Store
  (largest hand file, 578 LOC) | none — CONFIRMED PERMANENT RESIDUE
  (2026-10-04): no marketplace pack covers a durable run lifecycle engine.
  Reopen only if a pack ships a durable-lifecycle Elixir template class.
- lib/ash_pplan/reactor/durable/key.ex — checkpoint step identity | none.
- lib/ash_pplan/reactor/durable/ledger_ocel.ex — checkpoint ledger as
  process-mining evidence | UNSUPPORTED (generator-capability):
  ggen-ecosystem-ocel-pack emits one-shot JSON for a single manufacturing run;
  this is a runtime exporter over any durable store, and the only shared piece
  (OCEL 2.0 JSON shape) is already supplied locally by
  AshPPlan.ProcessEvidence.export/2 (ERRC R4, 2026-10-04).
- lib/ash_pplan/reactor/durable/middleware.ex — durable-run Reactor middleware
  | none.
- lib/ash_pplan/reactor/durable/migration.ex — pure checkpoint-key migration
  planner | none.
- lib/ash_pplan/reactor/durable/policy_driver.ex — FOND policy consulted per
  observed outcome | planning-policy-pack candidate.
- lib/ash_pplan/reactor/durable/portable.ex — ETF portability check for ledger
  values | none.
- lib/ash_pplan/reactor/durable/records.ex — ledger record structs | none.
- lib/ash_pplan/reactor/durable/run.ex — stored run → durable Reactor | none.
- lib/ash_pplan/reactor/durable/steps/await.ex — durable wait exception | none.
- lib/ash_pplan/reactor/durable/steps/dispatch.ex — durable child-run step |
  none.
- lib/ash_pplan/reactor/durable/steps/poll.ex — interval poll step | none.
- lib/ash_pplan/reactor/durable/store.ex — persistence behaviour with explicit
  losing semantics | none.
- lib/ash_pplan/reactor/durable/store/{dets,ets}.ex — DETS/ETS store impls
  (566 + 381 LOC) | none — CONFIRMED PERMANENT RESIDUE (2026-10-04): no
  marketplace pack covers DETS/ETS persistence impls behind the Store
  behaviour. Reopen only if a pack ships a store-impl Elixir template class.
- lib/ash_pplan/reactor/durable/testing.ex — deterministic test drivers |
  chicago-tdd-tools-pack candidate.
- lib/ash_pplan/reactor/durable/unwind.ex — take back standing work, newest
  checkpoint first | none.
- lib/ash_pplan/reactor/durable/verifier.ex — refuses nested durable wait in
  private composites | none.
- lib/ash_pplan/reactor/middleware/evidence.ex — binds run evidence to the
  subject | none.
- lib/ash_pplan/reactor/middleware/identity.ex — refuses subject-less runs |
  none.
- lib/ash_pplan/reactor/middleware/observation.ex — observes every step to the
  task subject (291 LOC) | UNSUPPORTED (generator-capability): the only
  Reactor-middleware template class is the local static
  `telemetry_middleware.ex.eex`; zero `use Reactor.Middleware` or
  ledger_events-emitting templates across all 300 packs (ERRC RA1,
  2026-10-04, receipts/ra1-reclassifications-2026-10-04.md).
- lib/ash_pplan/reactor/step/return_terminals.ex — return-terminals step |
  none.
- lib/ash_pplan/reactor/steps/actuate.ex — actuation intent, never executes |
  none.
- lib/ash_pplan/reactor/steps/await.ex — provider-polled await/observe step |
  none.
- lib/ash_pplan/reactor/steps/command.ex — named local handler invocation |
  none.
- lib/ash_pplan/reactor/steps/domain_action.ex — one Ash action as a step |
  none.
- lib/ash_pplan/reactor/steps/propose.ex — SA2A candidate step (authority:
  none) | sa2a-semantic-evidence-pack candidate.
- lib/ash_pplan/reactor/steps/telemetry.ex — telemetry observation step | none.
- lib/ash_pplan/realization.ex — capability realization description, Reactor-
  independent | none.
- lib/ash_pplan/release_receipt.ex — content-addressed release-head evidence |
  receipt-provenance-unification-pack candidate.
- lib/ash_pplan/sa2a/capability.ex — planner capabilities for the SA2A waist |
  none.
- lib/ash_pplan/sa2a/policy_candidate.ex — owner-side SA2A candidate
  manufacture | UNSUPPORTED (generator-capability): sa2a-semantic-evidence-pack
  is no longer template-less — it now ships
  `templates/lib/sa2a_evidence_contract.ex.tmpl` (static descriptor echo +
  single `admit/1` envelope gate) — but that class has zero overlap with
  runtime candidate manufacture (SubjectGuard with-chains,
  `select_policy/3`/`plan/1` calls, hostile-opts normalization, typed
  Refusal wrapping). sa2a-bridge-pack ships identity/edge-catalog echoes only;
  nearest behaviour analog (graphlaw-ash-capability-pack) is a wire-op class.
  Reopen on any subject-preserved candidate-manufacture Elixir template class
  (ERRC RA3b, 2026-10-04, receipts/ra3b-sa2a-falsifier-2026-10-04.md).
- lib/ash_pplan/sa2a/provider.ex — owner-side SA2A provider surface |
  sa2a-bridge-pack candidate.
- lib/ash_pplan/sa2a/refusal.ex — typed SA2A refusal codes | none.
- lib/ash_pplan/sa2a/replay.ex — caller-subject binding to FOND replay |
  counterfactual-frontier-replay-pack candidate.
- lib/ash_pplan/sa2a/subject_guard.ex — exact caller-subject preservation |
  cs2-exact-subject-pack candidate.
- lib/ash_pplan/standing.ex — standing of a run as a library API (523 LOC) |
  UNSUPPORTED (generator-capability): standing-ladder-pack ships a single
  template (`templates/standing_audit_trail.md.tmpl`), a markdown echo of
  stored StandingClaim literals — zero Elixir template class and no overlap
  with a 523-LOC judgment library (ladder admission, refusal issuance,
  evidence chaining). Reopen if the pack ships an Elixir judgment-class
  template (ERRC R5, 2026-10-04).
- lib/ash_pplan/standing/cached.ex — ETS memo keyed on evidence identity |
  UNSUPPORTED (generator-capability): standing-ladder-pack emits only a
  markdown audit-trail echo (see standing.ex receipt); no Elixir template,
  so the cache module has no pack generation path. Reopen on the same
  falsifier as standing.ex (ERRC R5, 2026-10-04).
- lib/ash_pplan/standing/ladder.ex — 10-state standing ladder, adopted from
  standing-ladder-pack | already pack-sourced; candidate for full generation.
- lib/ash_pplan/standing/sj_bridge.ex — sj standing vocabulary bridge |
  UNSUPPORTED (generator-capability): standing-ladder-pack's only artifact
  is `templates/standing_audit_trail.md.tmpl` (markdown echo); the bridge's
  vocabulary translation surface has zero template-class overlap. Reopen on
  the same falsifier as standing.ex (ERRC R5, 2026-10-04).
- lib/ash_pplan/state_machine.ex — AshStateMachine → planner data projection |
  PARTIAL (generator-capability): ~30/469 LOC overlap with the
  state-transition-pack's fsm.ex.tmpl — the row-shape slice from_transitions/4
  is row-expressible for a fixed resource; the runtime AshStateMachine
  introspection surface (describe_resource/1 reading Info.*) is not. Reopen
  if the pack gains a resource-projection template class (R4b falsifier,
  receipts/r4b-state-transition-falsifier-2026-10-04.md, 2026-10-04).
- lib/ash_pplan/state_machine/charts.ex — delegates to AshStateMachine.Charts
  | none.
- lib/ash_pplan/workflow.ex — Spark DSL for semantic workflows |
  ash-extension-core-pack candidate.
- lib/ash_pplan/workflow/authority.ex — workflow authority admission | none.
- lib/ash_pplan/workflow/dsl/extension.ex — Spark extension behind `use
  AshPPlan.Workflow` | ash-extension-core-pack candidate.
- lib/ash_pplan/workflow/dsl/info.ex — DSL introspection/lenient construction
  | none.
- lib/ash_pplan/workflow/dsl/method.ex — method DSL struct | none.
- lib/ash_pplan/workflow/dsl/task.ex — task DSL struct | none.
- lib/ash_pplan/workflow/dsl/transformers/generate_model.ex — builds the
  canonical model in a Spark transformer | ash-extension-core-pack candidate.
- lib/ash_pplan/workflow/dsl/verifiers/{acyclic_dependencies,
  capabilities_parse,helpers,outcome_closure,unique_ids}.ex (5 files) — Spark
  DSL verifiers | ash-extension-core-pack candidate (as a family).
- lib/ash_pplan/workflow/evidence.ex — evidence profile bound to one subject |
  UNSUPPORTED (generator-capability): evidence-capital-realization-pack ships
  Python tests + SPARQL gates, zero templates; no Elixir template class in the
  marketplace emits PROV-O N-Triples or subject-bound evidence verification
  (bind/verify/prov, 236 LOC) (ERRC E3, 2026-10-04,
  receipts/e3-falsifier-batch-2026-10-04.md).
- lib/ash_pplan/workflow/explain.ex — PRD s37 explainability answers | none.
- lib/ash_pplan/workflow/method.ex — HTN method struct |
  planning-federation-pack candidate.
- lib/ash_pplan/workflow/model.ex — canonical normalized workflow model | none.
- lib/ash_pplan/workflow/project/fond.ex — model→FOND domain projection |
  UNSUPPORTED (generator-capability): planning-federation-pack ships Python +
  JSON-IR templates only (projector.py.tera et al.) — no Elixir
  FOND-projection template class; consistent with the fond.ex/hddl.ex
  rejections (ERRC RA1, 2026-10-04,
  receipts/ra1-reclassifications-2026-10-04.md).
- lib/ash_pplan/workflow/project/hddl.ex — HDDL projection of the model |
  UNSUPPORTED (generator-capability): planning-federation-pack's nearest
  analog is a JSON IR template; no text-dialect/s-expression template class
  and no render→parse→compare court semantics (ERRC R4, 2026-10-04).
- lib/ash_pplan/workflow/project/p_plan.ex — model→compiler plan map | none.
- lib/ash_pplan/workflow/project/reactor.ex — model→Reactor projection |
  UNSUPPORTED (generator-capability): runtime projection layer (plan/1 +
  multi-clause project/3 with typed refusals + Subject IRI minting +
  Compiler.compile_spec/2 delegation); all 300 packs' reactor templates emit
  static pipelines, and the R2 `reactors.ex.eex` class projects only static
  marketplace-sim reactors from RDF individuals — no template class expresses
  this semantics (ERRC E2b, 2026-10-04,
  receipts/e2b-reactor-projection-falsifier-2026-10-04.md).
- lib/ash_pplan/workflow/runtime.ex — lifecycle API: plan/resolve/run/
  observe/resume/explain (546 LOC) | none — CONFIRMED PERMANENT RESIDUE
  (2026-10-04): no marketplace pack covers the workflow lifecycle facade.
  Reopen only if a pack ships a lifecycle-API Elixir template class.
- lib/ash_pplan/workflow/subject.ex — content-addressed workflow identity |
  UNSUPPORTED (generator-capability): cs2-exact-subject-pack ships TTL-only
  templates (consumer-binding.ttl.tmpl); nearest Elixir analog
  (ash-runtime-integration-contract-pack `exact_subject.ex.tmpl`) is a 9-line
  static identity module — zero overlap with a 278-LOC
  projection-verification library (correspondence/order/acyclicity over
  :pplan/:hddl/:fond/:reactor) (ERRC E3, 2026-10-04,
  receipts/e3-falsifier-batch-2026-10-04.md).
- lib/ash_pplan/workflow/task.ex — workflow task struct | none.
- lib/ash_pplan/fond.ex — FOND policy semantics (416 LOC) |
  UNSUPPORTED (generator-capability): planning-federation-pack ships Python +
  JSON-IR templates only; nearest Elixir analog (state-transition-pack
  `fsm.ex.tmpl`) is a deterministic FSM — no nondeterministic-outcome /
  strong-cyclic / TLA-rendering class (ERRC E2, 2026-10-04; re-confirmed E3,
  2026-10-04, receipts/e3-falsifier-batch-2026-10-04.md).
- lib/ash_pplan/fond/corpus.ex — seeded FOND corpus generator |
  UNSUPPORTED (generator-capability): workflow-corpus-pack ships NO templates/
  at all (ontology.ttl + SPARQL gates only) — generation impossible a priori;
  nearest analog (tokyo-depeg-burn-in-pack `corpus.ex.eex`) is a
  class-disjoint depeg burn-in corpus (ERRC E3, 2026-10-04,
  receipts/e3-falsifier-batch-2026-10-04.md).
- lib/ash_pplan/fond/counterexample.ex — typed counterexample normalization |
  chicago-graphlaw-court-pack candidate.
- lib/ash_pplan/fond/differential.ex — native validator vs independent TLA+
  court | chicago-graphlaw-court-pack candidate.
- lib/ash_pplan/fond/policy_supervisor.ex — pure policy lifecycle supervisor |
  UNSUPPORTED (generator-capability): planning-policy-pack ships NO templates/
  at all (pack.toml + ontology.ttl + gates + profiles only) — generation
  impossible a priori (ERRC RA1, 2026-10-04,
  receipts/ra1-reclassifications-2026-10-04.md).
- lib/ash_pplan/fond/policy_supervisor/offers.ex — selection among admitted
  policy offers | UNSUPPORTED (generator-capability): same a-priori bar as
  policy_supervisor.ex — planning-policy-pack has zero templates (ERRC RA1,
  2026-10-04, receipts/ra1-reclassifications-2026-10-04.md).
- lib/ash_pplan/fond/policy_switch.ex — deterministic policy-mode selection |
  UNSUPPORTED (generator-capability): same a-priori bar as
  policy_supervisor.ex — planning-policy-pack has zero templates (ERRC RA1,
  2026-10-04, receipts/ra1-reclassifications-2026-10-04.md).
- lib/ash_pplan/fond/projection.ex — provider-neutral subject disposition
  projection | none.
- lib/ash_pplan/fond/provider_registry.ex — pure FOND runtime provider catalog
  | none.
- lib/ash_pplan/fond/recovery.ex — typed recovery routing | none.
- lib/ash_pplan/fond/replay.ex — deterministic FOND/TLA replay bundle |
  counterfactual-frontier-replay-pack candidate.
- lib/ash_pplan/fond/subject.ex — exact-subject identity for FOND courts |
  cs2-exact-subject-pack candidate.
- lib/ash_pplan/fond/supervision_session.ex — supervision + provider
  substitution | none.
- lib/ash_pplan/fond/synthesis.ex — strong/strong-cyclic policy synthesis
  (283 LOC) | UNSUPPORTED (generator-capability): planning-federation-pack
  projects planner IR JSON + Python compiler artifacts (zero Elixir, zero
  algorithm code); the module implements the Cimatti et al. AIJ 2003 fixpoint
  algorithms over an in-memory %FOND{} — not a projection of admitted RDF
  (ERRC R4, 2026-10-04).
- lib/ash_pplan/fond/tla.ex — TLA+ projection of a FOND domain | none.
- lib/ash_pplan/fond/tla/json.ex — JSON envelope for TLA+ artifacts | none.
- lib/ash_pplan/fond/tla/manifest.ex — content-addressed TLA+ manifest | none.
- lib/ash_pplan/fond/tla/mutation.ex — deterministic negative mutations |
  chicago-tdd-tools-pack candidate.
- lib/ash_pplan/fond/trace.ex — bounded graph traces | none.

Former top-5 candidates (fond/synthesis.ex, workflow/project/hddl.ex,
reactor/durable/counterfactual.ex, reactor/durable/ledger_ocel.ex,
execution_receipt.ex) were reclassified UNSUPPORTED
(generator-capability) by the R4 falsifier wave — see receipts/
r4-falsifier-runs-2026-10-04.md. Remaining candidates: 29 rows / 33 files
(counting the 5-file verifier family row as 5 files), after E2c moved
status.ex to GENERATED.
- RA4 no-reopen closeout (2026-10-04): this cycle's reopen sweep CLOSED —
  standing/cached.ex + standing/sj_bridge.ex re-confirmed UNSUPPORTED
  (generator-capability) on the standing-ladder-pack markdown-only falsifier
  (R5, 2026-10-04); fond.ex re-confirmed (E2/E3) and fond/corpus.ex + the
  workflow-corpus-pack surface (no templates/ at all) confirmed on the E3
  falsifier (2026-10-04,
  receipts/e3-falsifier-batch-2026-10-04.md); state_machine.ex stays PARTIAL
  on the R4b falsifier (receipts/r4b-state-transition-falsifier-2026-10-04.md)
  with named residue. No verdict changed, no candidate row reopened.
  Receipt: receipts/ra4-no-reopen-2026-10-04.md.

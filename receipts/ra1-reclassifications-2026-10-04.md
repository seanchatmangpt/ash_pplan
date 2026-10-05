# RA1 Reclassifications (ERRC delta RA1, 2026-10-04)

Lane: RA1 of the 2026-10-04 ERRC delta wave. Scope: the four a-priori
reclassification targets from the delta plan — `reactor/middleware/observation.ex`,
`workflow/project/fond.ex`, the FOND policy family, and the `process_evidence`
adapters. Method: R4/E2 falsifier — public-surface file:line inventory per
module, then a template-class scan across all 300 packs in
`/Users/sac/ggen-marketplace/packs/` (183 Elixir template files scanned by
name; every name-adjacent template opened and read).

## Per-module verdicts

### lib/ash_pplan/reactor/middleware/observation.ex — UNSUPPORTED (generator-capability)

Public surface (291 LOC): `use Reactor.Middleware` (line 30); `events/0`
(:41), `init/1` (:48), `complete/2` (:51), `error/2` (:54), `halt/1` (:60),
`event/4` (:66), private observe/span ladder (:75-:243), `ledger_events/2`
(:197, :220) reading `context.durable.store` into `ProcessEvidence.Event`s.

Falsifier: the only Reactor-middleware template class on disk is the local
`priv/ggen/ash-pplan-reactor-mw-pack/templates/telemetry_middleware.ex.eex`
(one static telemetry module; no SPARQL rows, no observation/ledger_events
semantics). A name scan of all 300 packs' `templates/` finds zero
`use Reactor.Middleware` emission and zero `ledger_events` mentions; the
"observation" template hits are Python/JSON observability artifacts
(owning-rail, ggen-project-boundary, github-controloutcome-observation) in
non-Elixir classes. No template class expresses step-observation-to-evidence
serialization; generation impossible.

### lib/ash_pplan/workflow/project/fond.ex — UNSUPPORTED (generator-capability)

Public surface (216 LOC): `project/2` with typed refusal (:42-:73),
`split_outcomes/1` (:77), BFS outcome propagation
(`transitions/2` :83, `bfs/3` :112, `enqueue_successors/3` :130,
`successor_actions/5` :142, `branches/3` :180, insert helpers :201-:215).

Falsifier: planning-federation-pack `templates/` = binary.py.tera,
catalog.py.tera, interchange.py.tera, planner_ir.json.tera, projector.py.tera,
symbolic.py.tera — Python + JSON-IR only, zero Elixir. Nearest-analog class is
identical to the R4/E2/E3 rejections of fond.ex / hddl.ex / fond/corpus.ex:
no template class emits a model→domain projection with BFS outcome
propagation. Consistent UNSUPPORTED.

### FOND policy family (3 modules, 413 LOC) — UNSUPPORTED (generator-capability)

- `lib/ash_pplan/fond/policy_supervisor.ex` (170 LOC): `start/4` (:44),
  `horizon_exceeded?/1` (:73), `intent/1` (:76), `observe/3` (:98),
  `replace_domain/2` (:136), horizon witness (:161).
- `lib/ash_pplan/fond/policy_supervisor/offers.ex` (133 LOC): `new/3` (:12),
  `select/3` (:21), `next_action/1` (:48), `observe/4` (:58),
  `provider_down/2` (:81), `add_provider/2` (:90), `reselect/1` (:99),
  rank ladder (:130-:132).
- `lib/ash_pplan/fond/policy_switch.ex` (110 LOC): `select/3` sweep (:33-:46),
  `synthesize_and_validate/3` (:95).

Falsifier: `planning-policy-pack` (the named candidate on all three rows)
contains **no `templates/` directory at all** — pack.toml, ontology.ttl,
gates/010_select_is_not_do.rq, profiles/, qualification/consumer.ttl only.
Generation impossible a priori; nearest-analog comparison vacuous.

### lib/ash_pplan/process_evidence/ash_ex4pm.ex — GENERABLE (candidate retained; runbook below)

Public surface (162 LOC): `ex4pm_available?/0` (:20), `available?/0` (:23),
`envelope/2` (:27), `validate/2` (:52), `ingest/2` (:59), `activities/1`
(:70), pure envelope/context helpers (:81-:161).

Falsifier FOUND THE CLASS: `ash-ex4pm-evidence-pack/templates/
ex4pm_adapter.ex.tmpl` (192 lines) is explicitly generalized from this module
(template header comment: "generalized from
ash_pplan/lib/ash_pplan/process_evidence/ash_ex4pm.ex"). It renders per
`ex4ev:Emitter` SPARQL rows and emits the guarded envelope/validate/ingest
adapter (`Code.ensure_loaded?/1` guards, `Ex4pm.OCEL.validate_envelope/1`,
`Ex4pm.Stream.Ingest.ingest_envelope/2`, opt-in broadcaster). Same pattern as
E3's process_evidence.ex: an honest GENERABLE verdict blocks reclassification;
row stays a candidate pending qualification.

### lib/ash_pplan/process_evidence/ex4pm.ex — UNSUPPORTED (generator-capability)

Public surface (150 LOC): `@behaviour AshPPlan.ProcessEvidence` (:14),
`available?/0` (:19), `events/1` (:36), `export/2,3` (:39-:46),
`to_events/2` (:49), `to_event_log/2` (:54), `parse/2` (:79), serializer
(:93-:135), `map_event/1` (:135).

Falsifier: the evidence pack's remaining templates are class-disjoint —
`realtime_bridge.ex.tmpl` (GenServer ring-buffer bridge), `evidence_court.exs.tmpl`
(test court), and the GENERABLE `process_evidence.ex.tmpl` /
`ex4pm_adapter.ex.tmpl` cover the emitter and envelope-adapter classes, not
the Event→`Ex4pm.EventLog` struct-mapping + OCEL 2.0 serialize/parse-back
class (Ex4pm has no OCEL writer; this module supplies it over the real
reader). No template in any of the 300 packs mentions `EventLog` or
`to_events`. Class-disjoint → UNSUPPORTED.

## Score

- 6 rows falsified / 1,232 LOC: 5 UNSUPPORTED (generator-capability),
  1 GENERABLE (ash_ex4pm.ex — runbook below, row retained as candidate).
- Note: the scope of this wave did not include process_evidence/event.ex
  (row `none`, 20 LOC) or process_evidence.ex itself (already GENERABLE per
  E3).

## Conversion runbook: ash_ex4pm.ex ← ex4pm_adapter.ex.tmpl

Follows the E3 process_evidence.ex runbook shape (proof-of-concept diff
already exists as the template's source of generalization):

1. Declare the `ex4ev:Emitter` row for `AshPPlan.ProcessEvidence.AshEx4pm`
   (emitterNamespace `AshPPlan.ProcessEvidence`, emitterApp `ash_pplan`,
   emitterResource `AshPPlan.Workflow`, emitterAction from
   `ProcessEvidence.Event` usage) in the consumer ontology.
2. Render: run the ash-ex4pm-evidence-pack manifest with that row; output
   lands at `tmp/d6/consumer/lib/ash_pplan/process_evidence/ex4pm_adapter.ex`.
3. Diff against `lib/ash_pplan/process_evidence/ash_ex4pm.ex`; port the
   local-only bits upstream into the template class if any guard/helper is
   missing (`activities/1` via `AshEx4pm.Info` is the known local-only
   surface — check the rendered output for it and extend the template if
   absent, upstream, not in the generated copy).
4. Qualify: `mix test test/process_evidence` (or the ash_ex4pm-focused
   tests), plus compile of the rendered copy; a failure reopens the row as
   handwritten residue.

## Reopen triggers

- ash_ex4pm.ex reopens as handwritten residue if the runbook fails
  qualification.
- observation.ex reopens on any template class emitting
  `use Reactor.Middleware` with evidence/ledger serialization.
- workflow/project/fond.ex reopens on any Elixir FOND-domain-projection
  template class in planning-federation-pack (or any pack).
- The policy family reopens if planning-policy-pack ships templates at all.

## Totals after RA1 (grep-counted, not arithmetic)

Candidate-row recount before RA1 (observed 2026-10-04): **23 rows / 27
files** matched "pack candidate" — the ledger prose claimed 29/33, stale.
After RA1 edits: 17 rows remain literal "pack candidate" / 21 files; 2 rows
are GENERABLE candidates retained (process_evidence.ex, ash_ex4pm.ex).

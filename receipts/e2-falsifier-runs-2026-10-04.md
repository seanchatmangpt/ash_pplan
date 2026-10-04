# E2 Falsifier Receipt — pack-template coverage check (ERRC delta E2, 2026-10-04)

Method (same as ERRC R4/R5): enumerate every `.ex.eex` / `.ex.tmpl` / `.exs.eex` /
`.exs.tmpl` template across all 300 marketplace packs, name the template classes that
would have to cover each module, and confirm class overlap is zero. Enumeration run
2026-10-04: 175 Elixir template files across ~40 packs (full list captured in session;
packs with zero Elixir templates are not candidates by construction).

**Verdict: all four modules UNSUPPORTED (generator-capability).** Prior falsifiers
found zero Elixir core-runtime template classes; E2 re-runs the falsifier per module
and confirms zero overlap. No conversion runbook needed (no module turned GENERABLE).

## 1. lib/ash_pplan/fond.ex (416 LOC) — UNSUPPORTED (generator-capability)

Public surface: `AshPPlan.FOND` — `new/2` (lib/ash_pplan/fond.ex:47), `check/1`
(:72), `actions/2` (:101), `outcomes/3` (:110), `validate_policy/4` (:130),
`to_tla/5` (:157) — FOND domain struct + strong/strong-cyclic policy validation +
TLA+ rendering.

Template classes that would have to cover it, and the gap:
- planning-federation-pack: templates are all Python (binary/catalog/interchange/
  projector/symbolic `.py.tera`) plus `planner_ir.json.tera` — a JSON IR dump with
  `no_plan_statuses` strings. No policy-validation, nondeterministic-outcome, or
  TLA-rendering class; no Elixir template at all in the pack.
- state-transition-pack `fsm.ex.tmpl` — deterministic FSM (`st:Machine` /
  `st:Transition` with single `from`/`to`); FOND requires nondeterministic outcome
  sets per `state × action` and strong-cyclic fixpoint validation. Class mismatch.
- chicago-graphlaw-court-pack / ash-pplan-chaos-pack: court/property test suites
  (`.exs` only) — no module-generation class.
- graphlaw-ash-capability-pack: registry-surface families only (established R4).

## 2. lib/ash_pplan/compiler.ex (364 LOC) — UNSUPPORTED (generator-capability)

Public surface: `AshPPlan.Compiler` — `compile/2` (lib/ash_pplan/compiler.ex:61),
`compile_spec/2` (:80), private `validate_steps/1` (:116), `validate_predecessors/1`
(:140), `validate_handlers/1` (:156), `topological_order/1` (:189), `add_steps/4`
(:239), `bind_predecessors/2` (:288) — fail-closed P-PLAN validation → topological
sort → `Reactor.Builder.add_step` emission.

Template classes that would have to cover it, and the gap:
- ash-extension-pack / ash-extension-core-pack `reactor_pipeline.ex.tmpl`,
  `reactor_step.ex.tmpl` — declare a Reactor pipeline from an ontology's step list
  as static `step :name, StepModule do argument ... end` blocks at build time.
  The compiler is the inverse: a runtime that EMITS `Reactor.Builder` calls from
  arbitrary validated plan data. No template class expresses a plan-data→Builder
  compiler.
- ash-runtime-integration-contract-pack `reactor.ex.tmpl` — a 9-line static
  `use Reactor` scaffold with one hardcoded step; no validation, no topological
  sort, no Builder emission.
- ash-pplan-igniter-pack — single template `gen_workflow_task.ex.eex`, a Mix task
  (established G row); no compiler class.

## 3. lib/ash_pplan.ex (315 LOC) — UNSUPPORTED (generator-capability)

Public surface: `AshPPlan` root facade — `version/0` (lib/ash_pplan.ex:33),
`projections/0` (:36), `projection/1` (:39), `projections_for/1` (:42),
`plans/0` (:48), `plan/1` (:51), plus FOND pass-throughs `fond_domain/2` (:54),
`validate_policy/4` (:57), `synthesize_policy/3` (:66), `fond_subject/4` (:70),
`select_policy/3` (:74), `fond_replay/5` (:78), `fond_projection/5` (:82),
`differential_policy/5` (:86) — delegating facade over catalog + FOND + replay
surfaces with @spec'd facade functions.

Template classes that would have to cover it, and the gap:
- ash-pplan-igniter-pack (the row's named candidate): sole template is
  `gen_workflow_task.ex.eex` — a Mix task module (`def info/1`, `def igniter/1`
  at :63/:77). Zero facade/delegation-class overlap.
- ash-extension-pack `info.ex.tmpl` / `persist.ex.tmpl` — Ash extension
  `defmodule ... Info` / data-layer boilerplate, not a public-API facade.
- ex-noun-verb-cli-pack `registry.ex.tmpl` — CLI noun-verb registry, not an
  ontology-catalog facade.
- graphlaw-ash-capability-pack `capability_api.ex.tmpl` — registry API for
  capability families; covers registry-surface families only (established R4),
  not a facade delegating to Projection/Plan/FOND catalogs.

## 4. lib/ash_pplan/reactor.ex (299 LOC) — UNSUPPORTED (generator-capability)

Public surface: `AshPPlan.Reactor` — `adapters/0` (lib/ash_pplan/reactor.ex:41),
`step_for/2` (:53), `validate_step/1` (:76), `context_key/0` (:89),
`enrich/3` (:99) — enriches a live `%Reactor{}` with per-step workflow identity,
`identity_of/1` (:149), `inherit/2` (:166) — identity propagation across steps.

Template classes that would have to cover it, and the gap:
- ash-runtime-integration-contract-pack `reactor.ex.tmpl` — static scaffold
  (9-line `use Reactor` with one fixed step), not an enrichment/identity-propagation
  library over existing reactor instances.
- ash-extension-pack `reactor_step.ex.tmpl` — one static step module;
  `AshPPlan.Reactor` is a subject-bound identity-stamping layer over arbitrary
  steps (`identity_of/inherit` walk `Reactor.Step` structs at runtime). Class gap:
  no template expresses runtime inspection/mutation of `Reactor.Step` context.
- beam4pm-process-model-pack `beam4pm_claude_workflow_reactor.ex.eex` — a
  domain-specific workflow reactor module; statically emits steps, no generic
  enrich/inherit semantics.

## Totals

- 4/4 modules UNSUPPORTED (generator-capability), 2026-10-04.
- Marketplace corpus: 300 packs, 175 Elixir template files; zero template classes
  expressing (a) plan-data→Reactor.Builder compilation, (b) FOND policy semantics
  with nondeterministic outcomes + TLA rendering, (c) public-API facade over an
  ontology catalog, (d) runtime Reactor.Step identity enrichment.
- HANDWRITTEN.md: 4 rows updated to UNSUPPORTED (generator-capability), queue
  totals 33→29 rows.

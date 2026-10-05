# E2b Falsifier: workflow/project/reactor.ex (ERRC R5 delta, 2026-10-04)

Subject: `lib/ash_pplan/workflow/project/reactor.ex` (78 LOC, HANDWRITTEN).
Method: R4/E2-style — enumerate public surface, scan all marketplace packs for a
template class that could express it, verdict GENERABLE / PARTIAL / UNSUPPORTED.

## Pack scan

- Corpus: 300 packs in `/Users/sac/ggen-marketplace/packs` (counted 2026-10-04).
- Reactor-bearing Elixir templates (10 files): `ash-runtime-integration-contract-pack/templates/reactor.ex.tmpl`,
  `ash-extension-core-pack/templates/reactor_pipeline.ex.tmpl`,
  `ash-extension-pack/templates/reactor_pipeline.ex.tmpl`,
  `ash-extension-pack/templates/reactor_step.ex.tmpl`,
  `ash-extension-core-pack/templates/ash_reactor_extended_adapter.ex.eex`,
  `ash-extension-core-pack/templates/generic_action_bridge.ex.tmpl`,
  `ash-r2rml-reactor-paas-pack/templates/provision_reactor.ex.tmpl`,
  `ash-r2rml-paas-pack/templates/{lib/paas,mix.exs}.tmpl`,
  `beam4pm-process-model-pack/igniter/templates/beam4pm_claude_workflow_reactor.ex.eex`.
- `grep -c 'Reactor.Builder\|compile_spec\|def project'` across the five
  principal reactor templates: **0 hits in every file**. All emit static
  `use Reactor` DSL pipelines or literal echo structs. The only template in the
  marketplace carrying projection semantics (`projection-matrix-compose/templates/elixir-binding.ex.tmpl`)
  emits a literal attribute map (`def projection, do: %{...}`) — not a runtime
  projection API.
- **R2 template class check**: `priv/ggen/ash-pplan-workflow-pack/templates/reactors.ex.eex`
  (gates `120_reactor_workflows.rq`–`123_reactor_surface.rq`) emits
  data-driven but STATIC `use Reactor` DSL modules from `ap:Workflow`
  individuals (module, moduledoc, inputs, step bodies, return). It covers the
  marketplace-sim reactors only. It emits no runtime projection surface: no
  `plan/1`, no `project/2,3` multi-clause validation, no typed refusals
  (`:unbound_tasks` / `:invalid_bindings` / `:not_a_model` /
  `:unsupported_realization`), no `Compiler.compile_spec/2` delegation, no
  `Subject.correspondence/2` IRI minting.

## Public surface (file:line)

- `plan/1` — L15: builds the projection plan map (plan IRI + step IRIs +
  predecessors from `depends_on`).
- `project/3` (head L34; clauses L36, L44, L47): validates the model
  (`Model.validate/1`), refuses unbound tasks (`check_bound/2`, L68), builds
  the realization→step handler map via `AshPPlan.Reactor.step_for/1`
  (`handlers/3`, L55, with `:unsupported_realization` refusal), then delegates
  to `AshPPlan.Compiler.compile_spec/2`.
- `plan_iri/1` — L49, `step_iri/2` — L51: IRI minting via
  `AshPPlan.Workflow.Subject.correspondence/2`.

## Verdict

**UNSUPPORTED (generator-capability).** The module is a runtime
workflow-model→Reactor projection layer (validation + typed refusals + IRI
minting + delegation to the plan→Reactor.Builder compiler). No marketplace
template class — including the R2 `reactors.ex.eex` class, which projects
static sim reactors from RDF individuals — expresses this semantics. The
closest prior row evidence ("none") understated the falsification; this
receipt supersedes it with a dated per-module scan.

## Receipt fields

- Scan commands: pack count `ls packs | wc -l` = 300; template classes via
  `grep -rl 'reactor' packs --include='*.tmpl' --include='*.eex'` (10 Elixir
  reactor templates) and the 0-hit grep above; R2 template read in full
  (125 lines) + gates 120–123.
- Subject SHA: `git -C /Users/sac/ash_pplan rev-parse HEAD` at time of writing
  = 02723ba (working tree; read-only scan, no source edits).
- HANDWRITTEN.md updated: row `workflow/project/reactor.ex` none →
  UNSUPPORTED (generator-capability), dated 2026-10-04, citing this receipt.

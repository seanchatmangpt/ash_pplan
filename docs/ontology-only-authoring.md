# Ontology-Only Authoring

The design law: a user who ONLY edits RDF (`ontology.ttl` for shipped
capability, `test/support/examples/ontology/examples.ttl` for application
workflows) must be able to define and use everything the project offers — no
Ash knowledge, no hand-written Elixir.

## The path

1. Edit TTL only:

   - Capabilities: `ex:cap_X a ap:Capability ; ap:capabilityId "Fam.Op" ;
     ap:family "fam" .`
   - Providers: `a ap:Provider` with `ap:providerId`, `ap:providerModule`
     (choose a name; the module is generated, never hand-written),
     `ap:cost`, `ap:supportsCapability`, `ap:supportsProperty`,
     `ap:emitsEvidence`, and `ap:realization` rows (`ap:adapter`,
     `ap:operation`, `ap:stepOptions`).
   - Workflows: `a ap:Workflow` with `ap:workflowName`, `ap:goal`,
     `ap:hasTask`; Tasks with `ap:taskId`, `ap:requiresCapability`,
     `ap:authorityCeiling`, `ap:order`, `ap:dependsOn`, `ap:outcome`,
     `ap:requiresProperty`; compound tasks + `ap:Method` rows for
     decomposition.

2. Run manufacture:

   - `bin/manufacture-examples` — application workflows/providers/courts (test
     support), merged `ontology.ttl + examples.ttl`.
   - `priv/ggen/ash-pplan-workflow-pack/bin/manufacture-workflow` — shipped
     providers, index and capability catalog into `lib/`.

3. What lands where:

   - `test/support/examples/providers/<id>.ex` — generated provider modules
     (real behavior: capability/property/evidence/authority qualification and
     adapter+operation realization table).
   - `test/support/examples/workflows/<name>.ex` — generated workflow modules
     (`model/0`, `subject/0`, `hddl/0`).
   - `test/support/examples/runners/<name>.ex` — generated ontology-only
     runner (`AshPPlan.Examples.Runners.<Name>`): `run/2` (in-process),
     `run_durable/2` (durable engine over an ETS ledger; auto-starts the
     store, auto-selects providers from the generated index), `signal/4`,
     `resume/2`, plus `model/subject/hddl` mirrors.
   - `test/courts/examples/<name>_workflow_court_test.exs` and
     `<id>_provider_court_test.exs` — generated courts.
   - `planning/examples/<name>.hddl` — HDDL projection.

## Usage (zero consumer Elixir)

```elixir
{:ok, state} = AshPPlan.Examples.Runners.OntologyOnly.run_durable()
{:ok, explained} = AshPPlan.Workflow.Runtime.explain(state)
[wait] = explained.durable.waiting_on
{:ok, done} = AshPPlan.Examples.Runners.OntologyOnly.resume(state, signal: {wait, %{approved: true}})
```

An `ontology_only` workflow (both tasks through the built-in durable
adapter) is the standing falsifier:
`test/courts/examples/ontology_only_runner_court_test.exs` proves a run that
parks on a gate, resumes on a signal and completes, with the only authored
artifact being TTL rows.

## The honest boundary

What still needs Elixir, and why:

- Brand-new real-world side effects: a new op family whose adapter does not
  exist yet needs a hand-written `AshPPlan.Reactor.Adapter` + `Reactor.Step`
  module, then one `Application.put_env(:ash_pplan, :extra_adapters, ...)` —
  after which the TTL rows reference it like any built-in.
- The durable runner's ETS store is caller-linked; embedding it in a
  supervision tree is ordinary Elixir ops, not authoring.

The built-in adapter families (no Elixir required, reference them directly
from `ap:adapter`):

| ap:adapter | ops (examples) |
|---|---|
| local | actuation_command, actuation_actuate, state_observe, distributed_propose, observation_telemetry |
| durable | human_approve, event_await, state_await, schedule_deferred, workflow_dispatch |
| reactor_file | file_read, file_write, file_copy, file_delete, file_mkdir |
| reactor_req | `network_get/post/put/patch/delete/head`, remote_read |
| reactor_process | process_start, process_count, process_terminate |
| ash_reactor | `domain_create/read/update/destroy/action` |
| bb_reactor | actuator_command, state_await |
| ash_reactor_extended | extended Ash steps |

Worked examples all live as TTL in `examples.ttl`: `file_release`
(reactor_req + reactor_file), `qualified_fulfillment` (many families),
`ultracode`/`selfhost` (test-only adapters), and `ontology_only` (fully
built-in, zero test-only adapter).

## Upstream vocabularies are vendored, not private

The `p-plan:` and `prov:` terms in the authoring vocabulary are not private
inventions. Canonical P-PLAN 1.3 and PROV-O are vendored under `priv/vendor/`
(provenance in `priv/vendor/README.md`), `ontology.ttl` declares
`owl:imports` of the canonical namespaces, and every `p-plan:`/`prov:` term
used is court-verified as upstream-declared by
`test/courts/pplan_upstream_court_test.exs` — a private term is a refusal.

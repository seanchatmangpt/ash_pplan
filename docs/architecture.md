# Architecture

## Boundary

`ash_pplan` makes P-PLAN and PROV-O the conceptual interface. Ash, Reactor, AshStateMachine and AshOban/Oban remain the runtime owners. The project is a semantic/control plane over those runtimes, not a workflow engine competing with them.

```text
public process semantics
        |
        v
 P-PLAN + PROV-O
        |
        v
   ontology.ttl
        |
        v
     ash_pplan
        |
 +------+------+----------------+----------------+
 |             |                |                |
 v             v                v                v
HDDL/FOND    Reactor       AshStateMachine     AshOban
planning    DAG/saga       lifecycle state     activation/time
 |             |                |                |
 |             +----------------+----------------+
 |                              |
 +----------------------< observations/descriptors
```

Persistent application state remains Ash-native:

```text
FOND policy selects an admitted action
              |
              v
     authorized Ash action
              |
              +----------> dynamic P-PLAN -> AshPPlan.Action.Run -> Reactor
              |
              +----------> AshStateMachine transition legality
              |
              +----------> AshOban background/temporal delivery
              |
              v
       persisted resource / observed consequence
```

`AshStateMachine` does not become the workflow engine. Reactor does not become the persistent domain state machine. AshOban jobs do not become authoritative domain state. A FOND state is planner state; it is only identical to a resource state when an application explicitly chooses that projection.

## Descriptor law

Each integrated Ash extension has one adapter-owned resource descriptor:

```text
upstream public DSL / Info API
            |
            v
  resolved extension descriptor
   - configuration facts
   - configured capabilities
   - authority owner
            |
            v
   AshPPlan.ControlPlane
            |
            v
      combinatorial join
```

The control plane consumes descriptors. It does not introspect the same extension a second time and does not infer configured capabilities from dependency or extension presence.

This gives three distinct statements:

1. **supported** — the upstream extension provides a capability;
2. **configured** — this resource has supplied the configuration that makes the capability relevant;
3. **authorized/executed** — an owning runtime has actually admitted or performed an effect.

`ash_pplan` may establish the first two by observation. It does not manufacture the third.

## Ownership table

| Concern | Existing owner | ash_pplan treatment |
|---|---|---|
| dependency graph, concurrency, retry, compensation, undo, halt/resume | Reactor | project/observe/delegate |
| Ash action validation, authorization, actor and tenant | Ash | preserve; preferred DO boundary |
| Ash actions/resources inside a graph | Ash.Reactor | project |
| resource lifecycle legality | AshStateMachine | inspect/project |
| lifecycle atomicity, initial-state rules, `can?` preflight | AshStateMachine/Ash | expose owner/capability; do not duplicate |
| background jobs and record triggers | AshOban/Oban | inspect/project |
| recurring schedules, queues, retries, uniqueness | AshOban/Oban | inspect/project; do not duplicate |
| trigger job construction | AshOban | delegate as CONSTRUCT only |
| hierarchical decomposition | HDDL | validate/project |
| nondeterministic policy | FOND | validate |
| strong/strong-cyclic policy standing | `AshPPlan.FOND` | prove/refuse |
| Reactor outcome -> planner observation | Reactor + `AshPPlan.ReactorOutcome` | classify |
| continuation serialization/admission | `AshPPlan.Continuation` | capture/verify/restore |
| concrete continuation storage | downstream Ash application | contract only |
| process provenance | Reactor/Ash telemetry -> PROV-O | project |
| semantic conformance | SHACL (`ontology/shapes.ttl`) | enforce |
| release observation | CI exact-head qualification | observe |
| release evidence | `AshPPlan.ReleaseReceipt` | receipt |

## AshStateMachine adapter

`ash_state_machine` is a first-class package dependency. `AshPPlan.StateMachine` therefore uses its public modules directly rather than hiding API drift behind `Module.concat/1` or `apply/3`. If a public dependency contract changes, compilation should fail.

The adapter reads:

- `AshStateMachine.Info` for state attribute, state universes and transitions;
- `AshStateMachine.possible_next_states/1,2` for observation;
- `AshStateMachine.Charts` for diagrams;
- public built-in change/check modules only as authority identities.

It preserves the upstream wildcard invariant:

```text
states = wildcard_states ∪ deprecated_states
```

Deprecated states remain valid persisted values, but AshStateMachine excludes deprecated-only states from wildcard expansion. `action: :*` is expanded against the resource's concrete Ash update actions. This is an observation/projection operation; the planner does not invent actions.

The adapter does not execute `transition_state/1`, `next_state/1`, create/upsert transitions, policy checks, or persistence.

## AshOban adapter

`AshPPlan.Oban.describe_resource/1` uses the public combined introspection boundary `AshOban.Info.oban_triggers_and_scheduled_actions/1`. It describes resolved trigger and scheduled-action configuration once and derives resource capability facts from that evidence.

Examples:

```text
AshOban installed                      != retry_delivery?
max_attempts > 1                       => retry_delivery?
actor_persister/default_actor present  => actor propagation capability
list_tenants/use_tenant_from_record?   => tenant propagation capability
shared_context configured              => shared job context capability
chunks configured                      => chunk processing configured
scheduler_cron false                   => no trigger-based temporal activation
scheduled action / enabled cron        => temporal activation
```

`AshPPlan.Oban.construct_trigger/3` delegates to `AshOban.build_trigger/3`. The result is an Oban changeset at the **CONSTRUCT** boundary. No job is inserted, scheduled or executed by that API.

Worker/scheduler generation, durable storage, uniqueness, queue semantics, retry timing, tenant enumeration, actor restoration, cron leadership, Oban Pro chunk execution and all insertion/run APIs remain upstream.

## DfCM control plane

`AshPPlan.ControlPlane.describe/1` resolves the lifecycle and delivery descriptors once, then joins those facts with the Ash action catalog:

```text
Ash action
  × lifecycle transition membership
  × background activation membership
  × temporal activation membership
  × planner-selectable policy surface
  × Reactor outcome surface
  × continuation contract
```

The join is descriptive. For example, a single Ash update action may be both an AshStateMachine transition and an AshOban trigger target. `ash_pplan` can expose that relationship without calling the action.

Capability closure is evidence-derived. A missing actor persister, tenant configuration, chunk declaration, retry configuration or enabled cron remains false rather than being inferred from the presence of AshOban.

## Preferred downstream DO path

Ash should remain the application's action boundary. For a static Reactor module, the application can use that Reactor as the Ash generic-action implementation. For a P-PLAN compiled at runtime, configure an Ash generic action to run `AshPPlan.Action.Run`.

```elixir
action :run_plan, :map do
  argument :plan_iri, :string, allow_nil?: false
  argument :handlers, :map, allow_nil?: false
  argument :input, :map, allow_nil?: false

  run AshPPlan.Action.Run
end
```

Ash validates and authorizes the action and establishes actor/tenant context. `AshPPlan.Action.Run` then compiles the admitted P-PLAN and delegates orchestration to Reactor. `AshPPlan.execute/5` remains a lower-level engine API, not a replacement authorization boundary.

## Planning/control plane

```text
HDDL: what can this task decompose into?
FOND: given this state and nondeterministic outcomes, what action should be selected?
AshStateMachine: is that selected Ash action a legal persistent lifecycle transition?
Ash policy/action boundary: is this actor allowed to perform it?
Reactor: execute the admitted orchestration graph.
AshOban/Oban: deliver admitted background/temporal work.
PROV-O receipt: what actually happened?
```

`AshPPlan.FOND` accepts a finite transition relation such as:

```elixir
%{
  pending: %{attempt: [:pending, :succeeded]},
  succeeded: %{}
}
```

and a candidate policy such as `%{pending: :attempt}`. Strong standing requires every nondeterministic execution to reach a goal without fairness; strong-cyclic standing permits retry cycles when every reachable policy state retains a path to a goal under the fairness assumption.

The validator is pure. It does not call Reactor, Ash actions, external APIs, jobs, queues, or schedulers.

`AshPPlan.ReactorOutcome` maps Reactor's public result shapes to `:succeeded`, `:halted`, `:failed`, or `:unknown`. `AshPPlan.Oban.observation/1` separately maps delivery outcomes to `:succeeded`, `:snoozed`, `:cancelled`, `:failed`, or `:unknown`. A delivery state is not automatically a domain state; downstream FOND models must make that mapping explicitly.

## Durable continuation contract

Reactor can halt and later resume a halted Reactor. `AshPPlan.Continuation` supplies a durability envelope around that value without replacing Reactor's resume semantics.

```text
Reactor returns {:halted, reactor}
              |
              v
AshPPlan.Continuation.capture
  - halted-state check
  - plan/run identity check
  - ash_pplan version
  - Reactor version
  - codec id/version
  - content digest
              |
              v
application-owned Ash persistence
              |
              v
AshPPlan.Continuation.restore
  - schema/version compatibility
  - codec compatibility
  - payload + envelope identity
  - restored plan/run identity
              |
              v
AUTHORIZED ASH ACTION
              |
              v
AshPPlan.Continuation.resume
              |
              v
          Reactor.run
```

The default `AshPPlan.Continuation.ETFCodec` uses Erlang external term format but rejects pids, ports, references and functions recursively before encoding. `AshPPlan.Continuation.Store` defines the persistence contract but does not choose a data layer. Possession of a stored continuation is evidence, not resume authority.

The ontology projection for persistent continuation remains `status "gap"` because this package does not manufacture a universal storage resource or data layer.

## Manufacture

The root `ontology.ttl` is the only editable semantic source. `priv/ggen/ash-pplan-pack/ontology.ttl` is a symlink to it. The pack holds SPARQL gates and EEx templates that manufacture the runtime projection and plan catalogs.

| Gate | Selects | Manufactures |
|---|---|---|
| `010_projections.rq` | admitted `ap:Projection` rows | `AshPPlan.Generated.ProjectionCatalog` |
| `020_plan_steps.rq` | plan/step topology and precedence | `AshPPlan.Generated.PlanCatalog` |
| `030_plan_variables.rq` | per-step input/output variables | `AshPPlan.Generated.PlanCatalog` |

FOND/lifecycle/control-plane terms remain semantic classes rather than parallel runtime primitives. No generated catalog is an editing surface.

CI uses the exact ggen-ecosystem container digest recorded in `ecosystem.lock.toml` to parse the ontology independently. The Elixir job regenerates projections, tests the package and requires the manufactured source to remain unchanged.

## Conformance

`ontology/shapes.ttl` is executable admission:

```text
ontology.ttl
  -> bin/conform
  -> bin/conform-falsify
  -> ggen_igniter
```

`bin/conform-falsify` exists because a conformance gate that cannot reject a counterexample proves nothing.

## Construction versus downstream use

Construction HDDL decomposes the work required to evolve and qualify `ash_pplan`; construction FOND models nondeterministic engineering outcomes such as verification success/failure/refusal without pretending CI is deterministic.

Downstream HDDL decomposes application intent; downstream FOND models possible world outcomes and selects the next admitted action. The resulting action may invoke an Ash action, Reactor graph or observation step, but the planner itself does not actuate.

## Release observation and evidence

```text
exact head
  -> conform + falsify + container parse
  -> format + compile + mix check
  -> manufacture + generated diff
  -> package verification
  -> exact-head receipt
```

`AshPPlan.ReleaseReceipt` binds semantic/manufactured source identities and the exact Git subject. It is evidence, never authority to publish or merge.

## Extension law

A new runtime primitive is legal only when all are true:

1. the semantic concept cannot be represented faithfully with admitted public terms plus a thin adapter;
2. existing Reactor/Ash.Reactor/AshStateMachine/AshOban behavior is insufficient;
3. a concrete application reproduces the gap;
4. the proposed primitive has an executable falsifier;
5. the primitive does not steal authority from an existing owner.

This is why the refactor adds policy validation, compile-checked lifecycle/delivery descriptors, an Ash action adapter and a durable continuation envelope instead of another executor, queue or state-machine runtime.

# Architecture

## Boundary

`ash_pplan` makes P-PLAN and PROV-O the conceptual interface. Ash/Reactor/Oban/Elixir are implementation details of one projection. The project is a control-plane projection over those runtimes, not a workflow engine competing with them.

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
HDDL/FOND    Reactor        Ash.Reactor      AshOban/cron
planning    DAG/saga       Ash effects      activation/time
                |
                v
          Reactor outcome
                |
                v
       planner observation
```

Persistent resource lifecycle is a separate Ash-native axis:

```text
FOND policy selects an admitted action
              |
              v
          Ash action
              |
              v
       AshStateMachine
    transition validation
              |
              v
       persisted resource
```

`AshStateMachine` does not become the workflow engine and Reactor does not become the persistent domain state machine. A FOND state is a planner state; it is only the same thing as a resource state when the application explicitly chooses that projection.

## Ownership table

| Concern | Existing owner | ash_pplan action |
|---|---|---|
| dependency graph | Reactor | project |
| concurrency | Reactor | project |
| retry/backoff | Reactor | observe/model as nondeterministic outcome |
| failed-step compensation | Reactor | project |
| undo of successful prior steps | Reactor | project |
| halt/resume of an in-memory Reactor | Reactor | observe |
| dynamic step expansion | Reactor | project |
| Ash actions/resources | Ash.Reactor | project |
| resource lifecycle legality | AshStateMachine | introspect/project |
| actor/tenant/policy | Ash | preserve |
| background jobs | AshOban/Oban | project |
| record-state triggers | AshOban | project |
| recurring schedule | AshOban/Oban cron | project |
| hierarchical decomposition | HDDL | validate/project |
| nondeterministic policy | FOND | validate |
| strong/strong-cyclic policy standing | `AshPPlan.FOND` | prove/refuse |
| process provenance | Reactor/Ash telemetry -> PROV-O | project |
| semantic conformance | SHACL (`ontology/shapes.ttl`) | enforce |
| release observation | CI exact-head qualification | observe |
| release evidence | `AshPPlan.ReleaseReceipt` | receipt |
| durable halted continuation | application-owned Ash persistence | **gap** |

The last row remains intentionally explicit. Reactor can return a halted Reactor and later resume it, but that does not establish durable continuation across application/process/release boundaries. Persisting an Oban job or blindly serializing a Reactor term does not close that semantic gap.

## Planning/control plane

The planning model is deliberately split:

```text
HDDL: what can this task decompose into?
FOND: given this state and nondeterministic outcomes, what action should be selected?
AshStateMachine: is that selected Ash action a legal persistent lifecycle transition?
Reactor: execute the admitted orchestration graph.
PROV-O receipt: what actually happened?
```

`AshPPlan.FOND` accepts a finite transition relation:

```elixir
%{
  pending: %{attempt: [:pending, :succeeded]},
  succeeded: %{}
}
```

and a candidate policy:

```elixir
%{pending: :attempt}
```

It can establish either:

- **strong** standing: every nondeterministic execution reaches a goal without relying on fairness;
- **strong-cyclic** standing: retry cycles are allowed when every reachable policy state retains a path to a goal under the standard fairness assumption.

The validator is pure. It does not call Reactor, Ash actions, external APIs, or any DO boundary.

`AshPPlan.StateMachine` consumes AshStateMachine-style transitions directly or introspects an installed downstream `AshStateMachine` resource through `AshStateMachine.Info`. `from: :*` and `to: :*` can be expanded against the resource's declared state set. `action: :*` is refused for planning because a FOND policy must select a concrete action.

`AshPPlan.ReactorOutcome` maps Reactor's public result shapes to the bounded observations `:succeeded`, `:halted`, `:failed`, or `:unknown`. This closes the information loop without moving execution authority into the planner.

## Manufacture

The root `ontology.ttl` is the only editable semantic source. `priv/ggen/ash-pplan-pack/ontology.ttl` is a symlink to it. The pack holds three SPARQL gates and two EEx templates, and `ggen_igniter` manufactures two modules from them:

| Gate | Selects | Manufactures |
|---|---|---|
| `010_projections.rq` | admitted `ap:Projection` rows | `AshPPlan.Generated.ProjectionCatalog` |
| `020_plan_steps.rq` | plan/step topology and precedence | `AshPPlan.Generated.PlanCatalog` |
| `030_plan_variables.rq` | per-step input/output variables | `AshPPlan.Generated.PlanCatalog` |

The FOND/lifecycle ontology terms are intentionally semantic classes rather than new `ap:Projection` rows in this slice, so they do not manufacture a parallel execution primitive or require hand-editing generated catalogs.

CI uses the exact ggen-ecosystem container digest recorded in `ecosystem.lock.toml` to parse the public ontology independently of the Elixir build. The Elixir job then regenerates and executes the projection.

## Conformance

`ontology/shapes.ttl` is the admitted conformance profile for `ontology.ttl`, and it is executable rather than decorative:

```text
ontology.ttl
  -> bin/conform          (SHACL: does the canonical ontology conform?)
  -> bin/conform-falsify  (does the profile still refuse what it claims to?)
  -> ggen_igniter         (manufacture, only from an admitted ontology)
```

The profile refuses an unadmitted projection standing, a duplicate `ap:order` or `ap:sourceTerm`, a plan without a label, a step or variable outside any plan, a predecessor that is not a step, a predecessor in a different plan, and self-precedence. The last three are conditions `AshPPlan.Compiler` also refuses at compile time; refusing them at the semantic boundary means they never reach a manufactured catalog.

`bin/conform-falsify` exists because a conformance gate that cannot fail proves nothing. It reintroduces each counterexample against the real ontology and asserts the profile rejects it.

## Construction versus downstream use

The repository carries separate planning artifacts because construction and downstream execution are different worlds.

Construction HDDL decomposes the work required to evolve and qualify `ash_pplan`; construction FOND models nondeterministic engineering outcomes such as verification success/failure/refusal without pretending CI is deterministic.

Downstream HDDL decomposes application intent into process tasks; downstream FOND models possible world outcomes and selects the next admitted action. The resulting action may invoke an Ash action, a Reactor graph, or an observation step, but the planner itself does not actuate.

## Release observation and evidence

`planning/ship_v26_9_6.hddl` states three release goals — `released`, `observed` and `receipted` — and `planning/ash_pplan_v26_9_6.hddl` decomposes them through `verify`, `package`, `release`, `observe` and `receipt`. The release gate in `AGENTS.md` realizes `verify`, `package`, and the evidence that `observe` and `receipt` produce:

```text
exact head
  -> conform + falsify + container parse   (semantic qualification)
  -> mix check + manufacture + diff        (verified)
  -> mix hex.build                         (packaged)
  -> bin/receipt                           (release evidence)
```

`release` itself — a tag and a publish — has no realization in this repository. The gate runs on a `v*` tag so a tagged head is observed, but nothing here publishes, and `AGENTS.md` is explicit that a receipt grants no standing on its own.

`AshPPlan.ReleaseReceipt` digests the semantic source, the conformance profile, the producer lock and both manufactured catalogs at compile time, and binds the exact Git commit at receipt time. It is evidence about a release, never authority to publish one.

## Extension law

A new runtime primitive is legal only when all are true:

1. the semantic concept cannot be represented faithfully with admitted public terms plus a thin ash_pplan extension;
2. existing Reactor/Ash.Reactor/AshStateMachine/AshOban/scheduler behavior is insufficient;
3. a concrete application reproduces the gap;
4. the proposed primitive has an executable falsifier;
5. the primitive does not steal authority from an existing owner.

This is why the current refactor adds a policy validator and adapters, not another executor or state machine.

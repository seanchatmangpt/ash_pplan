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
| control-plane evidence export | `AshPPlan.ControlPlane` + `AshPPlan.FOND` validation results | project to `AshPPlan.FrontierEvidence`; CONSTRUCT ceiling, no actuation |
| Reactor outcome -> planner observation | Reactor + `AshPPlan.ReactorOutcome` | classify |
| durable run ledger and replay | `AshPPlan.Reactor.Durable.Engine` | claim/replay/park/unwind |
| durable storage | `AshPPlan.Reactor.Durable.Store` behaviour | ETS reference store; durable backends are consumer-supplied |
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
  × durable run ledger
```

The join is descriptive. For example, a single Ash update action may be both an AshStateMachine transition and an AshOban trigger target. `ash_pplan` can expose that relationship without calling the action.

Capability closure is evidence-derived. A missing actor persister, tenant configuration, chunk declaration, retry configuration or enabled cron remains false rather than being inferred from the presence of AshOban.

## Preferred downstream DO path

Ash should remain the application's action boundary. For a static Reactor module, the application can use that Reactor as the Ash generic-action implementation. For a P-PLAN compiled at runtime, configure an Ash generic action to run `AshPPlan.Action.Run`.

```elixir
action :run_plan, :map do
  argument :plan_iri, :string, allow_nil?: false
  argument :input, :map, allow_nil?: false

  run {AshPPlan.Action.Run,
       handlers: %{"https://w3id.org/ash-pplan#Step" => MyApp.Step},
       plans: ["https://w3id.org/ash-pplan#Plan"]}
end
```

Ash validates and authorizes the action and establishes actor/tenant context. `AshPPlan.Action.Run` then compiles the admitted P-PLAN and delegates orchestration to Reactor. `AshPPlan.execute/5` remains a lower-level engine API, not a replacement authorization boundary.

Step implementations are server-side configuration (`handlers:`), not caller input: an action argument naming `Reactor.Step` modules would let an API caller choose which loaded modules execute. A `:handlers` argument is honoured only when no `handlers:` option is configured, and is refused otherwise. `plans:` is an allowlist of plan IRIs. A failed outcome returns `{:error, _}` so Ash rolls back; a halt is refused (`:reactor_halted`) unless `allow_halt?: true`; inside a data-layer transaction Reactor runs with `async?: false` so every step joins that transaction.

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

`AshPPlan.FOND.Synthesis.synthesize/3` (facade: `AshPPlan.synthesize_policy/3`) constructs a policy instead of checking one. `:strong` is the backward attractor of the goal set: a state joins a layer when some action has every outcome in earlier layers, and the admitting action is recorded, so policy steps strictly lower the rank. `:strong_cyclic` is the greatest fixpoint of states that keep a path to a goal through policy-closed actions (actions whose outcomes all stay in the set); each round prunes actions that can leave the set, then drops states that lost their goal path. Synthesis is deterministic (term order, smallest admitted action) and the result is restricted to states reachable under the policy.

```elixir
{:ok, %{pending: :attempt}} = AshPPlan.synthesize_policy(domain, :pending, :strong_cyclic)
{:error, {:unsolvable, :strong, [:pending]}} = AshPPlan.synthesize_policy(domain, :pending, :strong)
```

The witness list holds every state reachable from the initial state under any action choice that lies outside the winning region. Every synthesized policy is admitted by `validate_policy/4`; `test/fond_synthesis_test.exs` checks this, and checks completeness against brute-force enumeration of every policy on fixture and seeded random domains. A synthesized policy is a SELECT/CONSTRUCT artifact and carries no actuation authority.

`AshPPlan.ReactorOutcome` maps Reactor's public result shapes to `:succeeded`, `:halted`, `:failed`, or `:unknown`. `AshPPlan.Oban.observation/1` separately maps delivery outcomes to `:succeeded`, `:snoozed`, `:cancelled`, `:failed`, or `:unknown`. A delivery state is not automatically a domain state; downstream FOND models must make that mapping explicitly.

## Durable ledger engine

Design derived from mbuhot/magma (MIT per its mix.exs); re-implemented. Reactor still executes the DAG; `AshPPlan.Reactor.Durable.*` records what each step produced so a run can park, be signalled, and resume.

```text
Engine.start(store, attrs)         idempotent by run id
Engine.attempt(store, run_id)
  claim (lease) -> Run.reactor_for(record) -> Run.decorate -> Reactor.run
    each step wrapped in Checkpointed:
      recorded?  replay through the impl (lands on the undo stack), reuse output
      otherwise  run, then record(insert-or-adopt)
    {:ok, r}      -> completed
    {:halted, _}  -> parked (:polling if any poll waiter, else :waiting)
    {:error, e}   -> unwinding -> failed / rolled_back
  release claim after the outcome is written
Engine.signal / wake / cancel      guarded status transitions
Unwind.run                         newest-first by checkpoint seq, claim_undo, up to 5 retries
```

Status transitions are guarded: a late attempt cannot overwrite `:cancelling` or `:unwinding`, and a terminal run is not re-run. Signals are consume-once; a signal wakes a parked run whatever it waits on, and also a run that is claimed. Releasing an already-released waiter succeeds.

Store: `AshPPlan.Reactor.Durable.Store` is the behaviour (runs, claims, checkpoints, undo claims, signals, waiters). `Store.Ets` is the reference implementation: single node, non-persistent. Atoms in ETF outputs are decoded with plain `binary_to_term` only inside this trusted store.

At-least-once boundary: a crash after a step's effect and before its checkpoint is written re-runs that effect. External effects need idempotency keys.

No definition versioning: runs are rebuilt from the stored model; changing a model under an in-flight run is not migrated.

Composites (group, around, recurse, compose) must not contain durable steps.

### Store backends

- `Store.Ets`: reference, single node, non-persistent.
- `Store.Dets`: one DETS file owned by one GenServer; every mutating call is followed by `:dets.sync/1`, so a restarted store on the same `:path` recovers runs, checkpoints, signals, waiters, claim leases and the sequence counter. Still single node. Both backends are held to one generated conformance suite (`bin/manufacture-store-conformance`).

### Guarded status machine

`Status` is the only table of legal transitions. The protocol is generated from the ontology into `priv/tla/durable/DurableProtocol.{tla,cfg}` and a transitions table (`bin/manufacture-durable-tla`); a TLC court model-checks the protocol, and a conformance court checks that the Elixir `Status` agrees with the generated relation. A chaos court (`bin/manufacture-durable-chaos`) kills and restarts the engine at each phase and asserts the ledger invariants.

### Replay semantics

An attempt rebuilds the Reactor from the stored model and re-runs it. A step with a recorded checkpoint is replayed through its implementation so it lands on the undo stack, and its recorded output is reused; a step without one runs and then records (insert-or-adopt). A parked deadline is read back from the waiter, never recomputed. Task ids are frozen identities: checkpoint keys derive from the step name (`Key.for_name/1`).

### Policy driver, counterfactuals, migration, standing

- `Durable.PolicyDriver`: a FOND domain plus an admitted (synthesized or supplied) policy. It returns the next action as data, checks observed outcomes against the domain, and carries a content fingerprint so a replay under another policy is detected. Selects structure only; authority `:none`, ceiling `:construct`.
- `Durable.Counterfactual.replay/3`: re-runs a recorded run in a private scratch store with one change (rebind a provider, override task policy, substitute an output). The original ledger is only read; its digest is identical before and after.
- `Durable.Migration.plan/3` and `apply/4`: map the tasks of one model onto another through subject correspondence for parked or pending runs. The plan is pure data; `apply` rewrites checkpoint keys and records evidence. This is the answer to "no definition versioning" for in-flight runs; it is explicit and receipted, not automatic.
- `AshPPlan.Standing`: `Standing = PlanCorrect and ExecutionCorrect and ObservedConsequenceCorrect`, each read from evidence or real post-state, with a five-field receipt (identity, authority, consequence, replay, standing) and a hash-chained ledger digest. Receipt ceiling is `CONSTRUCT`.

The ontology projection for persistent continuation remains `status "gap"`: this package does not manufacture a universal storage resource or data layer.

## Canonical falsification matrix

The canonical example court (`test/workflow/canonical_court_test.exs`) runs one example — the `QualifiedFulfillment` durable spine `admit_order -> authorize_payment -> await_human_release -> commit_shipment` — and that single spine validates all of the capabilities below. Chicago-style, every positive assertion against the real engine is paired with a negative control that must flip: a real behaviour-broken store or a genuinely corrupted input, never a mocked court.

| Capability | Positive assertion | Negative control / adverse event |
|---|---|---|
| Exactly-once ledger | Each spine effect runs once per run: `admit`/`authorize`/`commit` counts of 1 and a standing tape of the four spine steps. | A real double-record store (`MutantDoubleRecordStore` writes a shadow checkpoint per record) doubles the tape 4 -> 8 and the `length(tape) == 4` court flips. |
| Store interchangeability | The same canonical run leaves identical counts, tape and `:completed` status on `Store.Ets` and `Store.Dets`; a parked Dets run survives a store process restart and completes with all four steps. | A fresh store file has no run: `Engine.fetch/3` returns `nil`. |
| Protocol law | Every status move the canonical run makes (`pending -> waiting`, `waiting -> pending`, `pending -> completed`) is legal in the ontology-generated transitions table. | A corrupted terminal -> parked move (`completed -> waiting`) is refused by the same generated table. |
| Crash idempotency | Exactly-once is scoped to run identity: a run's recorded checkpoints replay instead of re-executing. | A fresh run id is a new run and re-executes effects (`admit` count 1 -> 2): the exactly-once assertion is honestly falsifiable, not decorative. |
| Kill at gate | A genuinely killed attempt leaves a dead claim; once the lease lapses on the test clock, a re-signal takes the run over and it converges `:completed` with effects exactly-once. | The crash is real (`spawn_monitor` + `Process.exit(..., :kill)`, `:DOWN` witnessed), not a simulated failure; takeover only happens after the lease lapse. |
| Early signal | A signal delivered before the first attempt is consumed by it: one attempt completes the run — no lost wakeup, no re-run. | A stranger-named signal still wakes the parked run (DECISION 30: any delivered signal wakes a parked run), which parks again having consumed it; the correctly-named signal then completes it. |
| Migration | A task rename (`authorize_payment` -> `verify_payment`) plans and applies to the parked run; the completed step replays without re-execution (effect counters unmoved). | Dropping a task that has a standing checkpoint is refused: `{:error, %{reason: :orphaned_checkpoints, orphaned: _}}` naming the orphaned task. |
| Counterfactual | `Counterfactual.replay/3` re-runs a recorded run in a private scratch store with one change; the original ledger digest is identical before and after. | A write into the original ledger is detected: `claim_undo/4` against a parked run's checkpoint flips the digest. |
| OCEL evidence | Every ledger event of the run is bound to the run's `subject_id`. | The hash-chained digest is tamper-evident: it changes the moment the ledger changes (witnessed by the counterfactual control). |
| Standing | An honest run is `:alive` (`verdict(:ok, :ok, :ok)`), and `Standing.receipt/2` over the run's own events yields a CONSTRUCT-ceiling receipt. | Dropping the FOND gate (no admitted successor path for `approved`) loses the plan layer; a false world check loses the consequence layer; a self-report with no observed consequence returns `{:lost, [:observed_consequence_correct]}`. |
| Authority | Plan admission enforces the CONSTRUCT ceiling on task authority. | A task declaring `authority: :do` is refused by `Model.validate/1`: `{:error, %{reason: :authority_above_ceiling, ceiling: :construct}}`. |
| Policy | `PolicyDriver.admit/1` selects structure only (ceiling `:construct`) against a real FOND domain and an admitted policy. | An inadmissible policy (`domain: nil`, empty policy) is refused `{:error, {:inadmissible_policy, _}}` before any effect. |
| Unwind / compensation | A failing commit lands the run `:failed`, terminal; effect steps without `undo/4` stay standing (carried forward, not reversed). | With the injected fault cleared, a fresh retry run completes, and the effect totals show the failed commit produced no stray success (`commit == 1` across both runs). |

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

This is why the refactor adds policy validation, compile-checked lifecycle/delivery descriptors, an Ash action adapter and a native durable run ledger instead of another executor, queue or state-machine runtime.

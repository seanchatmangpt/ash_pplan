# ash_pplan

**P-PLAN/PROV-O semantics projected into an Ash-native process control plane.**

`ash_pplan` deliberately does not introduce another workflow runtime. Reactor remains the DAG/saga executor. Ash remains the application action/policy boundary. AshStateMachine remains the persistent resource-lifecycle authority. AshOban/Oban remain the background and temporal activation layer.

`ash_pplan` fills the semantic/control-plane gaps between those owners: hierarchical process representation, FOND policy validation, compile-checked extension introspection, capability composition, Reactor outcome observations, content-addressed execution evidence, and a versioned durable-continuation contract.

| Public/process concept | Runtime/control-plane projection |
|---|---|
| `p-plan:Plan` | Reactor definition / builder |
| `p-plan:Step` | Ash.Reactor step/action binding |
| `p-plan:Variable` | Reactor input/argument/result |
| hierarchical decomposition | HDDL |
| nondeterministic policy | `AshPPlan.FOND` |
| persistent resource lifecycle | AshStateMachine + `AshPPlan.StateMachine` descriptor |
| application DO boundary | authorized Ash generic action |
| dynamic P-PLAN DO adapter | `AshPPlan.Action.Run` |
| Reactor outcome | `AshPPlan.ReactorOutcome` planner observation |
| background/temporal activation | AshOban/Oban + `AshPPlan.Oban` descriptor |
| semantic execution | `AshPPlan.Compiler` -> `Reactor.Builder` |
| halted continuation envelope | `AshPPlan.Continuation` |
| continuation persistence | downstream application implementing `AshPPlan.Continuation.Store` |
| composed capability view | `AshPPlan.ControlPlane` |
| execution evidence | `AshPPlan.ExecutionReceipt` |
| release observation | CI exact-head qualification |
| release evidence | `AshPPlan.ReleaseReceipt` |

## v26.9.7 contract

1. `ontology.ttl` remains the semantic source of truth.
2. `priv/ggen/ash-pplan-pack/ontology.ttl` remains a symlink to that source, so ggen_igniter cannot drift onto a second ontology.
3. `ggen_igniter` manufactures the runtime projection catalog and executable P-PLAN plan catalog.
4. `AshPPlan.Compiler` validates admitted topology before building a Reactor.
5. Executable behavior is explicitly bound by semantic step IRI to existing `Reactor.Step` implementations.
6. P-PLAN precedence becomes Reactor result dependencies; Reactor remains the scheduler/executor.
7. `AshPPlan.FOND` validates candidate strong and strong-cyclic policies without actuating them.
8. `AshPPlan.StateMachine` calls the public AshStateMachine contract directly and projects its resolved lifecycle without reproducing lifecycle validation.
9. `AshPPlan.Oban` calls the public AshOban introspection contract and derives capability facts from resolved resource configuration rather than extension presence.
10. `AshPPlan.ControlPlane` joins already-resolved descriptors; it does not rediscover or execute extension behavior.
11. Dynamic process execution should normally enter through an authorized Ash generic action using `AshPPlan.Action.Run`; `AshPPlan.execute/5` remains the lower-level engine API.
12. `AshPPlan.ReactorOutcome` converts Reactor public results into bounded planner observations.
13. `AshPPlan.Continuation` captures a halted Reactor in a versioned, content-addressed envelope; concrete storage remains application-owned.
14. `ontology/shapes.ttl` is executable conformance: `./bin/conform` must accept and `./bin/conform-falsify` must prove the profile still refuses.
15. Exact release heads are observable and receiptable through `AshPPlan.ReleaseReceipt`.

## Manufacture and qualification

```bash
mix deps.get
./bin/conform
./bin/conform-falsify
./bin/manufacture
mix check
./bin/verify-package
./bin/receipt
```

`bin/conform` and `bin/conform-falsify` need `rdflib` and `pyshacl`; `ecosystem.lock.toml` records the pins CI installs.

The generated source must remain unchanged after manufacture:

```bash
./bin/manufacture
git diff --exit-code -- lib/ash_pplan/generated
```

The repository pins its producer identities in `ecosystem.lock.toml`. CI independently validates the ontology inside the pinned `ggen-ecosystem` container, regenerates the Elixir catalogs with `ggen_igniter`, verifies the package from its own contents, and binds the release receipt to the exact checked-out Git head.

## FOND policy validation

A FOND domain is pure data:

```elixir
{:ok, domain} =
  AshPPlan.fond_domain(
    %{
      pending: %{attempt: [:pending, :succeeded]},
      succeeded: %{}
    },
    [:succeeded]
  )

policy = %{pending: :attempt}

{:ok, %{semantics: :strong_cyclic}} =
  AshPPlan.validate_policy(domain, policy, :pending, :strong_cyclic)
```

Strong validation requires all nondeterministic executions to reach a goal without relying on fairness. Strong-cyclic validation admits retry cycles when every reachable policy state retains a path to a goal under the fairness assumption.

The validator selects or rejects policy structure only. It does not call Reactor, Ash actions, external APIs, queues, or schedulers.

## AshStateMachine descriptor

`ash_state_machine` is a first-class dependency because lifecycle projection is now a supported package capability rather than a dynamically discovered optional surface. `AshPPlan.StateMachine` calls the public extension API directly so contract drift becomes a compile-time failure instead of a silent adapter degradation.

```elixir
{:ok, lifecycle} = AshPPlan.state_machine(MyApp.Subscription)
{:ok, domain} = AshPPlan.state_machine_domain(MyApp.Subscription, [:active])
{:ok, next_states} = AshPPlan.state_machine_next_states(subscription)
{:ok, mermaid} = AshPPlan.state_machine_diagram(MyApp.Subscription, :state)
```

The descriptor distinguishes the full persisted-state universe from AshStateMachine's wildcard universe. Deprecated states remain valid persisted values but are not automatically included in `:*` expansion. `action: :*` expands against the concrete Ash update-action universe; no planner action is invented.

`ash_pplan` never mutates the resource. Applications still transition through authorized Ash actions, and AshStateMachine remains authoritative for transition legality, atomic transition behavior, preflight checks, initial-state rules, and diagrams.

## AshOban descriptor

AshOban/Oban remain authoritative for workers, schedulers, queues, insertion, retries, uniqueness and durable delivery. `ash_pplan` observes the resolved DSL through `AshOban.Info`:

```elixir
{:ok, oban} = AshPPlan.oban(MyApp.Subscription)
{:ok, capabilities} = AshPPlan.oban_capabilities(MyApp.Subscription)
{:ok, trigger} = AshPPlan.oban_activation(MyApp.Subscription, :renew)
```

The capability map is **configuration-derived**. Installing AshOban does not imply that a resource has actor propagation, tenant fan-out, retry delivery, chunking, shared context, or an enabled cron scheduler. Those flags become true only when the resolved resource configuration supplies the corresponding evidence.

`AshPPlan.construct_oban_trigger/3` is deliberately a CONSTRUCT boundary:

```elixir
{:ok, changeset} = AshPPlan.construct_oban_trigger(subscription, :renew)
```

It delegates to `AshOban.build_trigger/3` and does not insert the job. Scheduling and execution stay behind the application's authorized Ash/AshOban DO path.

## Composed control plane

```elixir
{:ok, control_plane} = AshPPlan.control_plane(MyApp.Subscription)
```

`AshPPlan.ControlPlane` resolves each extension descriptor once and joins:

```text
Ash action
  x AshStateMachine lifecycle membership
  x AshOban trigger/schedule membership
  x FOND policy surface
  x Reactor observation surface
  x continuation contract
```

The join is descriptive. It maximizes visible combinations before selection without converting observation into authority.

## Preferred Ash-native execution boundary

For a dynamically compiled P-PLAN, configure a generic Ash action around `AshPPlan.Action.Run`:

```elixir
action :run_plan, :map do
  argument :plan_iri, :string, allow_nil?: false
  argument :handlers, :map, allow_nil?: false
  argument :input, :map, allow_nil?: false

  run AshPPlan.Action.Run
end
```

This preserves the normal Ash lifecycle: input validation, authorization, actor and tenant context happen before dynamic plan compilation/execution. `AshPPlan.Action.Run` then delegates the graph to Reactor and returns the observed outcome plus `AshPPlan.ExecutionReceipt`.

For lower-level engine code, the direct API remains available:

```elixir
handlers = %{
  "https://w3id.org/ash-pplan#AuthorizePayment" => MyApp.AuthorizePaymentStep,
  "https://w3id.org/ash-pplan#RenewSubscription" => MyApp.RenewSubscriptionStep
}

{{:ok, result}, receipt} =
  AshPPlan.execute(
    "https://w3id.org/ash-pplan#SubscriptionRenewal",
    handlers,
    %{subscription_id: "sub_123"},
    %{},
    run_id: "renewal-123"
  )
```

The compiler refuses malformed graphs, duplicate steps, dangling predecessors, cycles, missing handlers, invalid handlers, and unbounded terminal fan-out before Reactor execution begins. P-PLAN precedence is represented as real Reactor result dependencies.

## Durable halted continuation

Reactor owns halt/resume. `ash_pplan` adds a durability envelope around a halted Reactor:

```elixir
{:halted, reactor} = reactor_outcome

{:ok, continuation} =
  AshPPlan.capture_continuation(
    "https://w3id.org/ash-pplan#SubscriptionRenewal",
    "renewal-123",
    reactor
  )

attrs = AshPPlan.Continuation.to_attributes(continuation)
# Persist attrs through an authorized application-owned Ash resource/action.

{:ok, restored} = AshPPlan.restore_continuation(continuation)
```

The envelope binds schema version, P-PLAN identity, run identity, `ash_pplan` version, Reactor version, codec identity/version and payload digest. Restore refuses incompatible or tampered continuations.

The default ETF codec is deliberately conservative: pids, ports, references and functions are rejected recursively rather than being treated as durable simply because Erlang can serialize a term.

Storage is intentionally not built into this library. Applications implement `AshPPlan.Continuation.Store` with their chosen Ash data layer and authorization model. Loading a continuation does not itself grant authority to resume it; resume should occur inside the application's authorized Ash action boundary.

The ontology still marks the concrete persistent-continuation projection as a consumer-owned gap because there is no universal data layer or resource schema that `ash_pplan` can lawfully manufacture for every application.

## Planning artifacts

The repository distinguishes planning for **constructing ash_pplan** from planning for **using ash_pplan downstream**:

- `planning/ash_pplan_v26_9_6.hddl` — release/construction hierarchy.
- `planning/ash_pplan_v26_9_7.hddl` — semantic execution hierarchy.
- `planning/ash_pplan_control_plane.hddl` — HDDL ownership composition across policy, lifecycle, Reactor and observation.
- `planning/ash_pplan_construction.fond.pddl` — nondeterministic construction/qualification outcomes.
- `planning/ash_pplan_downstream.fond.pddl` — downstream policy example with retry/refusal outcomes.

This separation is intentional: HDDL decomposes intent; FOND controls nondeterministic choices; Ash validates application actions/resource transitions; Reactor executes the graph; receipts observe consequences.

## Release evidence

```bash
./bin/receipt
```

A release receipt binds the exact Git head plus semantic/manufactured source identities. It is evidence, not authority: it publishes, tags and approves nothing.

See `docs/architecture.md`, `docs/dfcm-ash-extension-closure.md`, `docs/semantic-execution.md`, the working-backwards press releases for v26.9.6/v26.9.7, and the planning artifacts under `planning/`.

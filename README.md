# ash_pplan

**P-PLAN/PROV-O semantics projected into an Ash-native process control plane.**

`ash_pplan` deliberately does not introduce another workflow runtime. Reactor remains the DAG/saga
executor. `AshPPlan.Reactor.Durable.*` adds a native durable ledger around it (no Oban, no
Postgres). Ash remains the application action/policy boundary. AshStateMachine remains the
persistent resource-lifecycle authority. AshOban/Oban remain the background and temporal activation
layer.

`ash_pplan` fills the semantic/control-plane gaps between those owners: hierarchical process
representation, FOND policy validation, compile-checked extension introspection, capability
composition, Reactor outcome observations, content-addressed execution evidence, and a native
durable run ledger (`AshPPlan.Reactor.Durable.*`).

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
| durable run ledger (checkpoints, signals, waiters) | `AshPPlan.Reactor.Durable.Engine` over an `AshPPlan.Reactor.Durable.Store` |
| durable store (reference) | `AshPPlan.Reactor.Durable.Store.Ets` (single node, non-persistent) |
| composed capability view | `AshPPlan.ControlPlane` |
| execution evidence | `AshPPlan.ExecutionReceipt` |
| release observation | CI exact-head qualification |
| release evidence | `AshPPlan.ReleaseReceipt` |
| control-plane evidence export | `AshPPlan.FrontierEvidence` |
| run standing (three-layer verdict, receipt) | `AshPPlan.Standing` (`verdict/3`, `receipt/2`), `AshPPlan.Standing.Receipt` |
| standing progression | `AshPPlan.Standing.Ladder` |
| OCEL 2.0 evidence export | `AshPPlan.Reactor.Durable.LedgerOCEL` |
| durable store (local file) | `AshPPlan.Reactor.Durable.Store.Dets` |
| counterfactual replay | `AshPPlan.Reactor.Durable.Counterfactual` |
| in-flight run migration | `AshPPlan.Reactor.Durable.Migration` |
| policy-driven step outcome | `AshPPlan.Reactor.Durable.PolicyDriver` |
| FOND policy driver surface | `AshPPlan.FOND` validation/synthesis, driven by `AshPPlan.Reactor.Durable.PolicyDriver` |
| verification surface | `bin/ggen-doctor`, `bin/ggen-verify`, `bin/ggen-replay-court`, `bin/ggen-engine-report` |

## Quickstart

```elixir
alias AshPPlan.Reactor.Durable.Testing
alias AshPPlan.Reactor.Durable.Store.Ets
alias AshPPlan.Workflow.Runtime

# 1. declare a workflow (Spark DSL or keyword model) with a human-release task
workflow = [name: "release", goal: "released", tasks: [
  [id: :select, capability: "Observation.Select", authority: :observe],
  [id: :gate, capability: "Human.Approve", after: [:select], authority: :observe]]]

# 2. start a run on the reference store; it parks on the human-release await
{:ok, store} = Ets.start_link()
{:ok, run} = Runtime.run(workflow, %{}, providers: MyApp.Providers, store: store, run_id: "rel-1")
run.observation.state                 #=> :halted

# 3. signal the release and resume; the recorded steps are replayed, not re-executed
[wait] = Testing.waiting_on(store, "rel-1")
{:ok, done} = Runtime.resume(run, signal: {wait, %{released: true}})
done.observation.state                #=> :succeeded

# 4. read the tape: standing checkpoint labels in order
Testing.tape(store, "rel-1")
```

Providers (`MyApp.Providers`) realize the capabilities; `test/workflow/durable_runtime_test.exs` is
the runnable version of this flow.

For persistence across a restart, use the DETS store: runs, checkpoints,
signals, waiters and claim leases survive a stopped or killed store process
when a new store is started on the same `:path`. A corrupted file fails closed
at startup, never opens half-readable:

```elixir
{:ok, store} = AshPPlan.Reactor.Durable.Store.Dets.start_link(path: "/tmp/ash_pplan.dets")
# ... runs, checkpoints and signals are recorded; every write is synced ...
GenServer.stop(store) # or the process is killed

{:ok, restarted} = AshPPlan.Reactor.Durable.Store.Dets.start_link(path: "/tmp/ash_pplan.dets")
AshPPlan.Reactor.Durable.Store.Dets.get_run(restarted, "rel-1")  #=> the run is intact
# a corrupt file refuses to open: {:error, {:dets_open_failed, _}}
```

### Limits

- The ETS store (`Store.Ets`) is single node and non-persistent: a node restart loses every run.
  `Store.Dets` persists to one local file, still single node. These are the only shipped stores; a
  clustered backend means implementing the `AshPPlan.Reactor.Durable.Store` behaviour.
- `Store.Dets` syncs the DETS file on every mutating call (`:dets.sync/1` after each write), so
  durability is synchronous — a stop, crash or `kill` loses nothing a caller was told succeeded, at
  the cost of write throughput.
- Effects are at-least-once across a crash: a crash between a step's effect and its checkpoint
  re-runs the effect. Use idempotency keys (`Durable.Key`).
- Task ids are frozen identities: a run is rebuilt from its stored model, so renaming or removing a
  task under an in-flight run is not migrated.
- The human-release await is park-on-signal: `Runtime.resume/2` without a `signal:` opt stays parked
  on the same waiter (no timeout firing), and a cancelled parked run is terminal — a second cancel
  or resume returns a typed refusal (`:not_cancellable` / `:not_resumable`).
- The durable ledger has no Postgres or Oban dependency by design; scheduling a parked run's wakeup
  (a background poller/deliverer) is host code, not shipped here.

## v26.10.1 contract

1. `ontology.ttl` remains the semantic source of truth.
2. `priv/ggen/ash-pplan-pack/ontology.ttl` remains a symlink to that source, so ggen_igniter cannot
   drift onto a second ontology.
3. `ggen_igniter` manufactures the runtime projection catalog and executable P-PLAN plan catalog.
4. `AshPPlan.Compiler` validates admitted topology before building a Reactor.
5. Executable behavior is explicitly bound by semantic step IRI to existing `Reactor.Step`
   implementations.
6. P-PLAN precedence becomes Reactor result dependencies; Reactor remains the scheduler/executor.
7. `AshPPlan.FOND` validates or synthesizes candidate strong and strong-cyclic policies without
   actuating them.
8. `AshPPlan.StateMachine` calls the public AshStateMachine contract directly and projects its
   resolved lifecycle without reproducing lifecycle validation.
9. `AshPPlan.Oban` calls the public AshOban introspection contract and derives capability facts from
   resolved resource configuration rather than extension presence.
10. `AshPPlan.ControlPlane` joins already-resolved descriptors; it does not rediscover or execute
    extension behavior.
11. Dynamic process execution should normally enter through an authorized Ash generic action using
    `AshPPlan.Action.Run`; `AshPPlan.execute/5` remains the lower-level engine API.
12. `AshPPlan.ReactorOutcome` converts Reactor public results into bounded planner observations.
13. `AshPPlan.Reactor.Durable.Engine` replays a run's recorded steps through their implementations,
    parks on signals and polls, and unwinds on cancel; storage is the
    `AshPPlan.Reactor.Durable.Store` behaviour.
14. `ontology/shapes.ttl` is executable conformance: `./bin/conform` must accept and
    `./bin/conform-falsify` must prove the profile still refuses.
15. Exact release heads are observable and receiptable through `AshPPlan.ReleaseReceipt`.
16. `AshPPlan.SA2A` (Capability, PolicyCandidate, Provider, Refusal, Replay, SubjectGuard) is an
    owner-side planner provider for ash_a2a. It projects P-PLAN/FOND/POWL candidates and replay
    admission; it observes and validates only and grants no DO authority.

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

`./bin/gate` runs every step above that this machine can run, in CI's order, and reports steps it
could not run (for example the pinned-container parse, which needs Docker) as `SKIP`, never as
passed. A local pass is not standing: CI's `release-gate` job on the exact head is.

`bin/conform` and `bin/conform-falsify` need `rdflib` and `pyshacl`; `ecosystem.lock.toml` records
the pins CI installs.

The generated source must remain unchanged after manufacture:

```bash
./bin/manufacture
git diff --exit-code -- lib/ash_pplan/catalog lib/ash_pplan/workflow lib/ash_pplan/providers
```

The repository pins its producer identities in `ecosystem.lock.toml`. CI independently validates the
ontology inside the pinned `ggen-ecosystem` container, regenerates the Elixir catalogs with
`ggen_igniter`, verifies the package from its own contents, and binds the release receipt to the
exact checked-out Git head.

The pack manufacture scripts honor `MANUFACTURE_MANIFEST_ROOT` to redirect generated ggen manifest
output away from the default `tmp/`; `bin/demonstrate` sets it to a per-process directory so its
regeneration steps replay in isolation.

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

Strong validation requires all nondeterministic executions to reach a goal without relying on
fairness. Strong-cyclic validation admits retry cycles when every reachable policy state retains a
path to a goal under the fairness assumption.

The validator selects or rejects policy structure only. It does not call Reactor, Ash actions,
external APIs, queues, or schedulers.

Policies can also be constructed, not only checked. `AshPPlan.synthesize_policy(domain, :pending,
:strong_cyclic)` returns `{:ok, policy}` — restricted to the policy-reachable states and admitted by
`AshPPlan.validate_policy/4` — or a typed refusal such as `{:error, {:unsolvable, mode,
witness_states}}`. `AshPPlan.FOND.Synthesis.solvable_states/2` exposes the winning region: every
state from which a policy of the requested class exists. Synthesis is SELECT/CONSTRUCT only: it
never calls Reactor, Ash actions, jobs, queues, or schedulers, and a synthesized policy carries no
actuation authority.

### TLA+ projection and TLC court

`AshPPlan.FOND.to_tla/4` renders the same domain, policy and initial state as a TLA+ module
and TLC config (render only; it never runs a checker):

```elixir
{:ok, %{module: tla, cfg: cfg, module_name: "FONDPolicy"}} =
  AshPPlan.FOND.to_tla(domain, policy, :pending, :strong_cyclic)
```

Each decided non-goal state becomes one action whose body is the disjunction of its
nondeterministic outcome branches; goals are absorbing; the checked property is `<>Goal`.
`:strong` renders no fairness over outcomes (only `WF_vars(Next)` progress), `:strong_cyclic`
conjoins `SF_vars` over every outcome branch. `test/fond_tla_test.exs` runs the pinned TLC
1.7.4 jar (`~/.cache/autofde-lab/tla2tools/1.7.4/tla2tools.jar`, SHA-256 checked) and requires
its verdict to equal `validate_policy/4` on every corpus case in both modes.

`test/fond_tla_hardening_test.exs` adds a second, JVM-free court: `AshPPlan.Test.TLAReader`
re-reads the rendered TLA+ text (and nothing else), decides deadlock and `<>Goal` under the
rendered `SF`/`WF` fairness, and must agree with `validate_policy/4` on the corpus and on 400
seeded random domains. CI fetches the pinned jar, checks its SHA-256 and sets
`ASH_PPLAN_REQUIRE_TLC=1`, so there the TLC court raises instead of skipping. Module names that
are TLA+ reserved words, standard modules or rendered identifiers are refused, and comment text
is printable ASCII. `MIX_ENV=test mix run bench/fond_tla_bench.exs` records render/reader/
validator timings; `test/fond_tla_bench_test.exs` bounds BEAM reductions (linear growth).

## AshStateMachine descriptor

`ash_state_machine` is a first-class dependency because lifecycle projection is now a supported
package capability rather than a dynamically discovered optional surface. `AshPPlan.StateMachine`
calls the public extension API directly so contract drift becomes a compile-time failure instead of
a silent adapter degradation.

```elixir
{:ok, lifecycle} = AshPPlan.state_machine(MyApp.Subscription)
{:ok, domain} = AshPPlan.state_machine_domain(MyApp.Subscription, [:active])
{:ok, next_states} = AshPPlan.state_machine_next_states(subscription)
{:ok, mermaid} = AshPPlan.state_machine_diagram(MyApp.Subscription, :state)
```

The descriptor distinguishes the full persisted-state universe from AshStateMachine's wildcard
universe. Deprecated states remain valid persisted values but are not automatically included in `:*`
expansion. `action: :*` expands against the concrete Ash update-action universe; no planner action
is invented.

`ash_pplan` never mutates the resource. Applications still transition through authorized Ash
actions, and AshStateMachine remains authoritative for transition legality, atomic transition
behavior, preflight checks, initial-state rules, and diagrams.

## AshOban descriptor

AshOban/Oban remain authoritative for workers, schedulers, queues, insertion, retries, uniqueness
and durable delivery. `ash_pplan` observes the resolved DSL through `AshOban.Info`:

```elixir
{:ok, oban} = AshPPlan.oban(MyApp.Subscription)
{:ok, capabilities} = AshPPlan.oban_capabilities(MyApp.Subscription)
{:ok, trigger} = AshPPlan.oban_activation(MyApp.Subscription, :renew)
```

The capability map is **configuration-derived**. Installing AshOban does not imply that a resource
has actor propagation, tenant fan-out, retry delivery, chunking, shared context, or an enabled cron
scheduler. Those flags become true only when the resolved resource configuration supplies the
corresponding evidence.

`AshPPlan.construct_oban_trigger/3` is deliberately a CONSTRUCT boundary:

```elixir
{:ok, changeset} = AshPPlan.construct_oban_trigger(subscription, :renew)
```

It delegates to `AshOban.build_trigger/3` and does not insert the job. Scheduling and execution stay
behind the application's authorized Ash/AshOban DO path.

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
  x durable run ledger
```

The join is descriptive. It maximizes visible combinations before selection without converting
observation into authority.

## Preferred Ash-native execution boundary

For a dynamically compiled P-PLAN, configure a generic Ash action around `AshPPlan.Action.Run`:

```elixir
action :run_plan, :map do
  argument :plan_iri, :string, allow_nil?: false
  argument :input, :map, allow_nil?: false

  run {AshPPlan.Action.Run,
       handlers: %{
         "https://w3id.org/ash-pplan#AuthorizePayment" => MyApp.AuthorizePaymentStep,
         "https://w3id.org/ash-pplan#RenewSubscription" => MyApp.RenewSubscriptionStep
       },
       plans: ["https://w3id.org/ash-pplan#SubscriptionRenewal"]}
end
```

This preserves the normal Ash lifecycle: input validation, authorization, actor and tenant context
happen before dynamic plan compilation/execution. `AshPPlan.Action.Run` then delegates the graph to
Reactor and returns the observed outcome plus `AshPPlan.ExecutionReceipt`.

Production rules:

- Configure `handlers:` on the server. A `:handlers` action argument is accepted only when no
  `handlers:` option is configured (backward compatibility); it lets the caller choose which
  `Reactor.Step` modules run, so do not expose it through a public API.
- `plans:` is an allowlist; a plan IRI outside it is refused with `:plan_not_allowed`.
- A failed Reactor outcome returns `{:error, errors}`, so Ash rolls back. A halt is refused with
  `:reactor_halted` unless `allow_halt?: true`.
- Inside a data-layer transaction Reactor runs with `async?: false`, so every step participates in
  that transaction.
- Refusals are `AshPPlan.Action.Run.Refusal` errors of class `:invalid`.

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

The compiler refuses malformed graphs, duplicate steps, dangling predecessors, cycles, missing
handlers, invalid handlers, and unbounded terminal fan-out before Reactor execution begins. P-PLAN
precedence is represented as real Reactor result dependencies.

## Extensibility

Adapters and capability families are host configuration, not forks: `config :ash_pplan,
:extra_adapters` merges additional adapter modules into `AshPPlan.Reactor.adapters/0`, and `config
:ash_pplan, :extra_capability_families` extends the shipped capability set. The built-in adapter
table was revised accordingly: `:ultracode` was removed (a binding with `adapter: :ultracode` must
now register its own adapter or migrate), and the generic `bb_reactor` and `durable` adapters ship
in the table. `AshPPlan.Reactor.Middleware.Observation` observes every step of a run — per-step
telemetry events, OpenTelemetry spans and `AshPPlan.ProcessEvidence` events, plus a run-level event
carrying the `ExecutionReceipt` and its PROV-O N-Triples.

## Durable ledger engine

`AshPPlan.Reactor.Durable.*` runs a workflow model as a durable ledger. Design derived from
mbuhot/magma (MIT per its mix.exs); re-implemented, with no dependency on magma. See
`docs/NOTICE.md`.

```elixir
{:ok, store} = AshPPlan.Reactor.Durable.Store.Ets.start_link([])

{:ok, run} =
  AshPPlan.Reactor.Durable.Engine.start(store, %{
    id: "renewal-123",
    model: model,
    bindings: bindings,
    inputs: %{subscription_id: "sub_123"},
    context: %{},
    parent: nil
  })

AshPPlan.Reactor.Durable.Engine.attempt(store, run.id)
# {:completed, result} | {:parked, :waiting | :polling} | {:failed, error}
# | {:rolled_back, status} | :taken | :ended | :not_found

{:ok, _signal} = AshPPlan.Reactor.Durable.Engine.signal(store, run.id, "approved", %{by: "ops"})
AshPPlan.Reactor.Durable.Engine.attempt(store, run.id)
```

Parts:

- `Engine`: `start/2` (idempotent by run id), `attempt/3` (claim with lease, replay, guarded status
  transitions), `signal/4`, `wake/2`, `cancel/2`, `runnable?/3`, `runnable/2`.
- `Run`: rebuilds the Reactor from the record's model and bindings, wraps every step in
  `Checkpointed`, and runs it.
- `Unwind`: newest-first undo of checkpointed steps on cancel or failure.
- `Steps.Await`, `Steps.Poll`, `Steps.Dispatch`: signal wait, poll-until, and child-workflow steps.
  Options are data (integers, atoms, `{m, f, args}`), not closures.
- `Store`: the persistence behaviour. `Store.Ets` is the reference implementation: single node and
  non-persistent, so a node restart loses runs. A durable backend implements the same behaviour.
- `Testing`: `drain/2`, `tape/2`, `recorded/3`, `age_deadline/4` and signal helpers for
  deterministic tests with a test clock.

Replay semantics: an attempt re-runs the plan; a step with a recorded checkpoint is replayed through
its implementation so it lands on the undo stack, and its recorded output is used instead of
re-executing the effect. A parked deadline is never recomputed. A terminal run is never re-run.

Delivery boundary: the engine is at-least-once. A crash between running a step's effect and
recording its checkpoint re-runs the effect on the next attempt. Steps with external effects must
use an idempotency key (for example derived with `AshPPlan.Reactor.Durable.Key`) so a repeat is
harmless.

No definition versioning: a run is rebuilt from the model stored in its record. There is no
migration of in-flight runs across model changes.

Nesting composites (group, around, recurse, compose) must not contain durable steps; the verifier
refuses them.

The ontology still marks the concrete persistent-continuation projection as a consumer-owned gap;
the ETS store does not close it.

## Planning artifacts

The repository distinguishes planning for **constructing ash_pplan** from planning for **using
ash_pplan downstream**:

- `planning/ash_pplan_v26_9_6.hddl` — release/construction hierarchy.
- `planning/ash_pplan_v26_9_7.hddl` — semantic execution hierarchy.
- `planning/ash_pplan_control_plane.hddl` — HDDL ownership composition across policy, lifecycle,
  Reactor and observation.
- `planning/ash_pplan_construction.fond.pddl` — nondeterministic construction/qualification
  outcomes.
- `planning/ash_pplan_downstream.fond.pddl` — downstream policy example with retry/refusal outcomes.

This separation is intentional: HDDL decomposes intent; FOND controls nondeterministic choices; Ash
validates application actions/resource transitions; Reactor executes the graph; receipts observe
consequences.

## Control-plane evidence export

`AshPPlan.FrontierEvidence.from_control_plane/3` is a deterministic
FrontierEvidence v1 projection of ash_pplan control-plane data: it takes
already-resolved control-plane descriptors and FOND validation results and
emits a schema-`frontier-evidence/v1`, content-addressed (`sha256:`
`artifact_hash`) evidence envelope carrying a `CONSTRUCT` authority
ceiling, for a downstream admission court. The input descriptors and FOND
validation results must already exist; the adapter refuses nothing and
actuates nothing — no Ash action, lifecycle transition, Oban
insertion/schedule, Reactor execution, or durable run attempt — preserving
ash_pplan's descriptive SELECT/CONSTRUCT boundary while making that
evidence portable to the court.

Execution-side evidence rides the same boundary: `AshPPlan.ProcessEvidence` converts an
`AshPPlan.ExecutionReceipt` and its subject into task-level events
(`task_attempted`/`task_succeeded`/`task_failed`) and exports pure OCEL 2.0 JSON. When the
`ex4pm`/`ash_ex4pm` dependencies are present (dev/test until published), the
`ProcessEvidence.AshEx4pm` adapter validates and ingests the same events through `Ex4pm`'s envelope
API. Like the projection above, it observes and emits only — it grants no authority.

## Release evidence

```bash
./bin/receipt
```

A release receipt binds the exact Git head plus semantic/manufactured source identities. It is
evidence, not authority: it publishes, tags and approves nothing.

## Canonical case studies

The case studies under `docs/case-studies/` are the canonical worked examples of this
contract. Honesty rule: every figure in them cites its receipt under `receipts/`; each
case study is reproducible with `bin/case-study`.

See `docs/architecture.md`, `docs/archive/dfcm-ash-extension-closure.md`,
`docs/semantic-execution.md`, the working-backwards press releases for v26.9.6/v26.9.7 under
`docs/archive/`, and the planning artifacts under `planning/`.

## Upstream ontologies & the GCP lifecycle simulation

ash_pplan does not maintain a private P-PLAN. The canonical P-PLAN 1.3
(archived from `vocab.linkeddata.es`, CC-BY-4.0, Garijo/Gil) and PROV-O
(`w3.org`) are vendored under `priv/vendor/`. The court
`test/courts/pplan_upstream_court_test.exs` pins the vendored files to the
canonical distributions and refuses any `p-plan:` or `prov:` term used in
`ontology.ttl` that is not declared upstream. See
`docs/ontology-only-authoring.md` for the authoring-law consequence.

`test/support/marketplace_sim/` simulates the GCP Marketplace lifecycle
in-process: a Google-side ProcurementApi (13-event entitlement state fold)
and Pubsub (ordered per-topic fan-out, duplicate delivery), and vendor-side
Portal (JWT signup tokens), MeteringServer (dedup + half-open-window usage
aggregation) and Billing (EDP committed-spend drawdown over ETS). Each
participant is a real GenServer (Billing: real shared ETS) driven by courts
under Chicago rules. The full 8-step lifecycle plan, with agents, inputs and
outputs, is `test/support/marketplace_sim/lifecycle_plan.ttl`. See
[docs/gcp-lifecycle-simulation.md](docs/gcp-lifecycle-simulation.md).

## Simulation & dashboard surfaces (2026-10-04)

- Marketplace sim participants: Google ProcurementApi (13-event entitlement
  fold) + Pubsub, vendor Portal/MeteringServer/Billing as real GenServers,
  courted under Chicago rules — gate:
  `mix test test/support/marketplace_sim/metering_billing_court_test.exs
  test/support/marketplace_sim/pubsub_portal_court_test.exs`.
- Lifecycle plan: 8-step GCP Marketplace lifecycle in canonical P-PLAN 1.3 +
  PROV-O vocabulary — `test/support/marketplace_sim/lifecycle_plan.ttl`;
  structural + execution court: `mix test
  test/courts/gcp_lifecycle_plan_court_test.exs`.
- Petal web dashboard: GCP lifecycle explorer (`/`) + real-time fleet
  dashboard (`/dashboard`, real durable runs + telemetry) — launch:
  `bin/dashboard --port 4100`; sources in `test/support/marketplace_sim/web/`.
- GCP pack generated validation: `gcp-marketplace-saas-pack`-generated
  consumer module pinned to live Cloud Commerce Procurement API enums/events
  — `test/support/marketplace_sim/gcp_generated/gcp_generated_validation.ex`
  (covered by the marketplace_sim courts above).
- Protocol court: TLA+ / Stateright / Elixir transition surfaces all rendered
  from one protocol-court pack ontology — manufacture:
  `bin/manufacture-protocol-court`; consumer gate:
  `mix test test/durable/protocol_court_test.exs`.
- Pack-inventory court: closes ggen.toml <-> on-disk pack drift — `mix test
  test/courts/pack_inventory_court_test.exs`.
- Realization-adapter court: every `ap:Realization` (adapter, operation) pair
  resolves through the real adapter API — `mix test
  test/courts/realization_adapter_court_test.exs`.
- Catalog-execution court: liveness assertions on the GENERATED projection/
  plan catalogs — `mix test test/courts/catalog_execution_court_test.exs`.
- Runtime contract courts: 86 zero-row cross-contract courts + admission
  gates — `bin/runtime-contract-courts` (also
  `test/durable/runtime_contract_court_test.exs`).
- P-PLAN upstream court: pins vendored P-PLAN 1.3 + PROV-O
  (`priv/vendor/`), refuses private vocabulary — `mix test
  test/courts/pplan_upstream_court_test.exs`.

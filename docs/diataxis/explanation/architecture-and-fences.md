# Architecture and fences: why `ash_pplan` is shaped this way

This page explains the reasoning behind the package's shape: why it is a
control plane rather than another workflow engine, why the ontology is
canonical and the code is partly generated, and why a set of explicit fences
separates observation, construction and actuation. It is about *why*; the
*how* lives in the how-to guides and the *what* in the reference pages.

## The ecosystem already has owners

Ash applications do not lack execution machinery. Reactor owns DAG and saga
execution — concurrency, retries, compensation, undo, halt and resume
(`docs/architecture.md`, ownership table). Ash owns validation, authorization,
policies, actors and tenancy. AshStateMachine owns the legality of persistent
resource lifecycle transitions. AshOban and Oban own background delivery,
scheduling, queues, uniqueness and retries. Each of these is the authority for
its concern; `ash_pplan` treats them as owners, not as competitors.

A fourth workflow engine would duplicate that authority, and duplicated
authority drifts: two implementations of retries or transition legality
inevitably disagree under edge conditions, and the disagreement surfaces as
corrupted application state. The design choice instead is to fill the gaps
*between* the owners — the semantic gaps. `ash_pplan` contributes the
P-PLAN/PROV-O vocabulary for processes, hierarchical decomposition (HDDL),
FOND policy validation and synthesis, compile-checked extension descriptors,
execution evidence, and a native durable run ledger
(`README.md` projection table). Every one of those is a concern no existing
owner expresses; none of them re-expresses a concern an owner already owns.

The consequence is a one-way dependency of responsibilities. A FOND policy can
*select* an Ash action, but only an authorized Ash action may perform it. A
Reactor graph may *contain* an AshStateMachine transition, but the legality of
that transition is judged only by AshStateMachine. An AshOban trigger may
*deliver* work, but the durable state of the work is not Oban's job record.
`docs/architecture.md` states the negative forms directly: AshStateMachine does
not become the workflow engine, Reactor does not become the persistent domain
state machine, Oban jobs do not become authoritative domain state, and a FOND
state is planner state — identical to a resource state only when an
application explicitly chooses that projection. The same discipline applies to
outcomes: `AshPPlan.Oban.observation/1` classifies delivery as
`:succeeded`/`:snoozed`/`:cancelled`/`:failed`, and `AshPPlan.ReactorOutcome`
classifies graph results, but a delivery state is not automatically a domain
state — a downstream FOND model must make that mapping explicitly.

## Why ontology-first, with generated projections

The package's authority section (`AGENTS.md`) ranks P-PLAN and PROV-O terms
above Elixir names, generated files, framework DSLs and documentation. The
mechanism that enforces the ranking is simple: `ontology.ttl` at the repo root
is the only editable semantic source, and `priv/ggen/ash-pplan-pack/ontology.ttl`
is a symlink to it, so the ggen_igniter pack cannot quietly acquire a second
ontology that drifts from the first.

From that source, SPARQL gates and EEx templates manufacture code:
`010_projections.rq` produces `AshPPlan.Catalog.Projection`, and the
plan-step and variable gates produce `AshPPlan.Catalog.Plan`
(`docs/architecture.md`, manufacture table). The manufactured modules under
`lib/ash_pplan/catalog/`, `lib/ash_pplan/workflow/`, and `lib/ash_pplan/providers/` are consequences, not sources. Repairing a defect
by editing a generated file fixes the symptom at the wrong layer, and the next
`./bin/manufacture` run silently reverts the repair. The manufacture gate makes
this falsifiable: CI regenerates and requires
`git diff --exit-code` over the manufactured directories — the projection must be a
deterministic function of the ontology.

Two layers of conformance sit above generation. `ontology/shapes.ttl` is the
executable SHACL profile of the ontology, admitted by `./bin/conform` and
attacked by `./bin/conform-falsify`. The falsifier exists because a
conformance gate that cannot reject a counterexample proves nothing — a gate
that always passes is indistinguishable from no gate. Finally, CI parses the
ontology again inside the pinned ggen-ecosystem container recorded in
`ecosystem.lock.toml`, so the semantic source is validated by an identity
independent of the local toolchain.

## The descriptor law: three statements that must not blur

Every integrated extension gets one adapter-owned descriptor that separates
three claims:

1. **Supported** — the upstream extension provides a capability.
2. **Configured** — this specific resource has supplied the configuration that
   makes the capability relevant.
3. **Authorized/executed** — an owning runtime has actually admitted or
   performed an effect.

The reason for the law is that installing an extension is not evidence that
any optional capability is in use. The AshOban adapter
(`lib/ash_pplan/oban.ex`, described in `docs/architecture.md`) derives its
capability map from resolved configuration, never from extension presence:
`max_attempts > 1` is evidence for retry delivery; a missing actor persister or
a `scheduler_cron: false` is evidence *against* actor propagation or temporal
activation. AshStateMachine installed says nothing about whether a given
resource declares transitions.

The rule that empty collections must not create positive claims through
vacuous predicates is the guard against the subtle failure: a descriptor that
asks "does the configuration contain an actor persister?" over an empty
collection and derives a universal truth would promote level 1 into level 2
by accident. Absence of configuration is a negative fact and must remain one.
`AshPPlan.ControlPlane` (`lib/ash_pplan/control_plane.ex`) then joins
already-resolved descriptors — it does not re-introspect an extension a second
time and does not execute any behavior it describes. Level 3 is never
manufactured by the descriptor layer at all; it exists only as receipts of an
owning runtime.

## The SELECT / CONSTRUCT / DO fence

The sharpest fence in the package separates three verbs. Observation and
policy *selection* (SELECT) grant no actuation authority. *Construction* of a
changeset or a plan (CONSTRUCT) is also not actuation. Only a *DO* — an
authorized action performed by the owning runtime — changes the world.

The Oban boundary shows the fence precisely: `AshPPlan.construct_oban_trigger/3`
delegates to `AshOban.build_trigger/3` and returns a changeset. Building a
changeset is CONSTRUCT. Insertion, scheduling and execution remain AshOban/Oban
operations behind the application's authorized path
(`docs/architecture.md`, AshOban adapter). The FOND validator is fenced the
same way from the other side: `AshPPlan.FOND` validates or synthesizes
strong and strong-cyclic policies as pure data, and "the validator is pure —
it does not call Reactor, Ash actions, external APIs, jobs, queues, or
schedulers" (`README.md`, FOND section). A synthesized policy is a
SELECT/CONSTRUCT artifact and carries no actuation authority.

For dynamic plans, DO enters through Ash, not around it. `AshPPlan.Action.Run`
(`lib/ash_pplan/action/run.ex`) is configured as an Ash generic action, so
input validation, policy authorization and actor/tenant context are established
by Ash *before* `AshPPlan.execute/5` delegates the graph to Reactor. The
production rules follow from the fence: `handlers:` is server-side
configuration, not a caller-supplied argument, because an action argument
naming `Reactor.Step` modules would let an API caller choose which loaded
modules execute; `plans:` is an allowlist; a failed outcome returns an error so
Ash rolls back (`docs/architecture.md`, preferred downstream DO path).
`AshPPlan.execute/5` remains a lower-level engine API, not an alternative
authorization boundary.

Receipts close the fence on the evidence side. An `AshPPlan.ExecutionReceipt`
records the run and a digest of the observed outcome; an
`AshPPlan.ReleaseReceipt` binds the exact Git head and manufactured source
identities. Both are evidence, never authority — a receipt publishes, merges
and approves nothing. Compilation refusals produce no receipt at all, because
"a refusal is not an execution" (`docs/semantic-execution.md`): nothing ran,
so there is nothing to observe.

## The durable store fence, and the magma derivation

Reactor executes graphs in-process; a run that must park for a human approval
and resume tomorrow needs a ledger. `AshPPlan.Reactor.Durable.*` adds that
ledger *around* Reactor without replacing it: the `Engine` claims a run with a
lease, the `Run` module rebuilds the Reactor from the stored model and wraps
every step in `Checkpointed`, and `Unwind` undoes checkpointed steps
newest-first on cancel or failure.

The fence is at the storage layer: all persistence goes through the
`AshPPlan.Reactor.Durable.Store` behaviour, and the engine, run, unwind and
step code never touch ETS or a backend directly (`AGENTS.md`, durable store
fence). This is why the shipped stores can be honest about what they are.
`Store.Ets` (`lib/ash_pplan/reactor/durable/store/ets.ex`) is single node and
non-persistent — a reference implementation, not a durability claim. A node
restart loses every run. `Store.Dets` (`lib/ash_pplan/reactor/durable/store/dets.ex`)
persists to one local file on one node. Any new backend must pass the generated
store-conformance suite (`bin/manufacture-store-conformance`) before use, so
"implements the behaviour" and "actually behaves as a store" are separately
proven. The ontology's `ap:projection-persistent-continuation` remains marked
as a gap for the same reason of honesty: the package ships no universal
persistent storage resource, and marking the gap is preferred to a claim the
reference store cannot support.

Other durability rules are consequences of the at-least-once delivery
boundary. A crash between a step's effect and its checkpoint re-runs the
effect, so external effects need idempotency keys (`AshPPlan.Reactor.Durable.Key`).
A step with a recorded checkpoint is replayed *through its implementation* — so
it lands on the undo stack — and its recorded output is reused instead of
re-executing the effect; a parked deadline is read back, never recomputed; a
terminal run is never re-run; status transitions are guarded so a late attempt
cannot overwrite `:cancelling` or `:unwinding` (`docs/architecture.md`,
durable ledger engine). Durable steps are refused inside nesting composites,
and step options are data (integers, atoms, `{m, f, args}`), never closures —
a closure cannot survive a checkpoint.

The design is derived from mbuhot/magma, which upstream declares MIT in its
`mix.exs` (`docs/NOTICE.md`). What is derived is the design — checkpointed
steps replayed through their implementations, signals and waiters, claim
leases, newest-first unwinding, guarded transitions. What is *not* copied is
the code: the engine was re-implemented against Reactor 1.0.7 and Ash 3.33.
What is *not* depended on is magma itself, Oban or Postgres. Keeping the
ledger free of an Oban/Postgres dependency is what lets it sit behind the
Store behaviour as a neutral run ledger, orthogonal to the delivery layer
that AshOban already owns.

## Public compile-time contracts over reflection

First-class dependencies are integrated through their public compile-time
contracts (`AGENTS.md`, public-contract law). `AshPPlan.StateMachine` calls
`AshStateMachine.Info`, `possible_next_states/1,2` and `Charts` directly;
`AshPPlan.Oban` reads the combined introspection boundary
`AshOban.Info.oban_triggers_and_scheduled_actions/1` (`docs/architecture.md`,
adapter sections). The alternative — hiding API access behind
`Module.concat/1` and `apply/3` — converts contract drift from a compile error
into a runtime failure on whatever path the tests happen not to reach. With
public modules, `mix compile --warnings-as-errors` is the falsifier: if
AshStateMachine changes its contract, the build breaks and the drift is
visible immediately. Dynamic module lookup is reserved for genuinely optional
surfaces, such as the `ex4pm`/`ash_ex4pm` process-evidence adapters that are
present only in dev/test until published (`README.md`, execution-side
evidence).

The semantic-execution compiler applies the same philosophy inside the
package. P-PLAN precedence becomes real Reactor result dependencies under
fixed argument names drawn from a bounded list, rather than atoms derived from
IRIs at runtime; fan-in past the bound is refused (`docs/semantic-execution.md`).
Refusal before execution — malformed graphs, cycles, dangling predecessors,
missing or invalid handlers — is preferred to discovering the same defect mid-run.

## Why fences at all

Every fence here encodes the same judgment: one authority per concern. The
extension law (`docs/architecture.md`) makes the judgment explicit as an
admission test — a new runtime primitive is legal only when the semantic
concept cannot be represented with admitted public terms, existing owner
behavior is insufficient, a concrete application reproduces the gap, an
executable falsifier exists, and the primitive does not steal authority from
an existing owner. That test is why this package grew FOND validation,
descriptors, an Ash action adapter and a durable ledger instead of another
executor, queue or state machine — and why its standing vocabulary
(`AGENTS.md`) distinguishes evidence (`ALIVE`, `PARTIAL_ALIVE`) from
capability (`UNSUPPORTED`) and from refusal (`REFUSED_*`): a claim about this
package's behavior is only as good as the observation behind it, which is the
same fence applied to the package's own documentation.

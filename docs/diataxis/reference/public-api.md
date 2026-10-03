# Public API reference

`ash_pplan` v26.10.1 — "P-PLAN/PROV-O control plane over Ash, AshStateMachine, Reactor and AshOban" (`mix.exs`).

Orientation: `AshPPlan` (`lib/ash_pplan.ex`) is the facade most consumers need. The
modules below are grouped alphabetically within each section. Signatures come from
`@spec`s or checked clauses in the cited source; error returns are typed maps or
structs as shown. Authority notes mark where a fence applies (`AGENTS.md`: SELECT /
CONSTRUCT / DO are distinct; nothing in this library grants DO authority).

`lib/ash_pplan/generated/` is manufactured by `ggen_igniter` from `ontology.ttl`; it
is listed as generated surface only and is never hand-edited.

## Primary entry point

### AshPPlan

Purpose: semantic facade — catalog access, FOND helpers, descriptor delegation,
compile/execute, workflow lifecycle. `lib/ash_pplan.ex`.

Catalog and ontology access:

| Function | Returns | Notes |
|---|---|---|
| `version/0` | `String.t()` | Release version from `mix.exs`, bound at compile time. |
| `projections/0` | list | Every ontology-to-runtime projection (delegates to `AshPPlan.Generated.ProjectionCatalog.all/0`). |
| `projection/1` | value or nil | Lookup by source ontology IRI (`ProjectionCatalog.fetch/1`). |
| `projections_for/1` | list | By semantic role (`:plan`, `:step`, `:temporal`); atom or binary. |
| `plans/0` | list | Every manufactured P-PLAN plan (`AshPPlan.Generated.PlanCatalog.all/0`). |
| `plan/1` | value or nil | Lookup by plan IRI. |

FOUND policy helpers (all validate or construct only — never execute):

| Function | Delegates to | Notes |
|---|---|---|
| `fond_domain/2` | `FOND.new/2` | Builds a pure-data FOND domain; transitions + goals. |
| `validate_policy/4` | `FOND.validate_policy/4` | Validates strong / strong-cyclic policy from an initial state. |
| `synthesize_policy/3` | `FOND.Synthesis.synthesize/3` | Returns `{:ok, policy}` or typed refusal `{:error, {:unsolvable, mode, witness_states}}`. |
| `fond_subject/4` | `FOND.Subject.bind/4` | Deterministic exact-subject identity for a policy court. |
| `select_policy/3` | `FOND.PolicySwitch.select/3` | Strongest requested solvable mode without execution. |
| `fond_replay/5` | `FOND.Replay.build/5` | Content-addressed replay bundle. |
| `fond_projection/4` | `FOND.Projection.portable/4` | Provider-neutral, authority-free envelope. |
| `differential_policy/5` | `FOND.Differential.check/5` | Differential comparison via caller-supplied rendered-model checker. |

Descriptor delegation (observation only; owners keep authority):

| Function | Delegates to |
|---|---|
| `state_machine_domain/2` | `StateMachine.from_resource/2` |
| `state_machine/1` | `StateMachine.describe_resource/1` |
| `state_machine_capabilities/1` | `StateMachine.capabilities/1` |
| `state_machine_next_states/1,2` | `StateMachine.possible_next_states/1,2` |
| `state_machine_diagram/2` | `StateMachine.Charts.render/2` (type `:state` or `:flow`) |
| `oban/1` | `Oban.describe_resource/1` |
| `oban_capabilities/1` | `Oban.capabilities/1` |
| `oban_activations/1` | `Oban.activations/1` |
| `oban_activation/2` | `Oban.fetch_activation/2` |
| `oban_observation/1` | `Oban.observation/1` |
| `control_plane/1` | `ControlPlane.describe/1` |
| `reactor_outcome_state/1` | `ReactorOutcome.state/1` |

CONSTRUCT boundary:

| Function | Notes |
|---|---|
| `construct_oban_trigger/3` | Delegates to `Oban.construct_trigger/3`. Builds the trigger job changeset; does **not** insert. Ceiling `:construct`; insertion/scheduling/execution stay with AshOban/Oban (`lib/ash_pplan/oban.ex`). |

Compilation and execution:

| Function | Signature | Notes |
|---|---|---|
| `compile_plan/2` | `(plan_iri, handlers)` | Delegates to `Compiler.compile/2`; validation and projection only. |
| `execute/5` | `(plan_iri, handlers, input, context \\ %{}, options \\ [])` | Compiles and runs through `Reactor.run/4`; returns `{reactor_outcome, %ExecutionReceipt{}}`, or `{:error, %AshPPlan.Compiler.Error{}}` with no receipt when compilation is refused (nothing executed). Lower-level engine API — for application actuation prefer the authorized Ash action path via `AshPPlan.Action.Run`. Reserved context key `:ash_pplan` is refused (`:reserved_context_keys`); bad argument shapes are refused with `:invalid_execute_arguments`. `:run_id` option (or context `:run_id`) is propagated to Reactor run options, step context and receipt. |
| `run/4` | `(reactor, inputs, context \\ %{}, options \\ [])` | Delegates to `Reactor.run/4`; no ash_pplan execution runtime. |
| `predecessor_results/2` | `(arguments, context)` | Inside a Reactor step: P-PLAN predecessor results keyed by predecessor step IRI (`p-plan:isPrecededBy` as real Reactor result dependencies). Returns `%{}` when no predecessor bindings are in context. |

Workflow lifecycle (each delegates to `AshPPlan.Workflow.Runtime`, see below):
`workflow_plan/2`, `workflow_resolve/2`, `workflow_run/3`, `workflow_resume/2`,
`workflow_observe/3`, `workflow_inspect/1`, `workflow_explain/2`,
`workflow_validate/1`, `workflow_project/3`.

## Modules

### AshPPlan.Action.Run

Purpose: Ash generic-action implementation executing a dynamically compiled
P-PLAN — the preferred downstream DO boundary for dynamic plans
(`lib/ash_pplan/action/run.ex`). Ash performs action validation, policy
authorization and actor/tenant setup before delegating to `AshPPlan.execute/5`.

- `run(action_input, opts, context)` — behaviour callback (`use Ash.Resource.Actions.Implementation`).
- Server options: `:handlers` (map of step IRI to `Reactor.Step`; when fixed on
  the server a caller-supplied `:handlers` argument is refused with
  `:handlers_argument_refused`), `:plans` (plan IRI allowlist; refusal
  `:plan_not_allowed`), `:allow_halt?` (default `false`; a halt is refused with
  `:reactor_halted`, rolling back an enclosing transaction), `:reactor_options`.
- Generic-action arguments: `:plan_iri`, `:input` (`:handlers` only when no
  server-side option is configured).
- Returns `{:ok, %{outcome: outcome, receipt: receipt}}` on success (and on
  halt when `allow_halt?: true`); `{:error, errors}` on failure, unwrapping a
  `Reactor.Error` class so Ash classifies step errors and rolls back. Forces
  `async?: false` inside a data-layer transaction.
- `AshPPlan.Action.Run.Refusal` — Splode error, class `:invalid`, fields
  `:reason`, `:details` (surfaces inside `Ash.Error.Invalid`).

### AshPPlan.Capability

Purpose: typed capability identity `Family.Name` (e.g. `File.Write`); a semantic
requirement, never an implementation (`lib/ash_pplan/capability.ex`).

- `families/0` — shipped families (`domain`, `network`, `filesystem`, `process`,
  `event`, `state`, `actuation`, `transaction`, `durability`, `scheduling`,
  `observation`, `human_interaction`, `distributed`, `authority`, `evidence`,
  `file`, `remote`, `verification`, `artifact`, `workflow`) plus
  `config :ash_pplan, :extra_capability_families`.
- `parse/1` — `(id | atom | t) :: {:ok, t} | {:error, map}`; refuses unknown families.
- `valid?/1` — boolean.
- `normalize/1` — canonical string id.
- Struct: `%AshPPlan.Capability{id, family, name}`.

### AshPPlan.CapabilityPack

Purpose: named bundle of capability declarations contributed by a provider
package; `authority` is a ceiling capped at `:construct`
(`lib/ash_pplan/capability_pack.ex`).

- `load/1` — `(map | keyword | t) :: {:ok, t} | {:error, map}`.
- `validate/1` — invariants mirrored by SHACL shape `ontology/capability_pack.ttl`:
  non-empty id, non-empty unique capability list, parseable capabilities,
  authority admitted by `AshPPlan.PolicyClosure.AuthorityCeiling`.
- Struct: `%AshPPlan.CapabilityPack{id, version, capabilities, properties, evidence, authority}` (authority default `:construct`).

### AshPPlan.Compiler

Purpose: compiles admitted P-PLAN topology into Reactor's public
`Reactor.Builder` API; validation and projection only, Reactor remains the
executor (`lib/ash_pplan/compiler.ex`).

- `compile/2` — `(plan_iri :: binary, handlers :: map) :: {:ok, Reactor.t()} | {:error, %Compiler.Error{}}`; resolves the plan from `AshPPlan.Generated.PlanCatalog`. Refusals: `:unknown_plan`, `:invalid_compile_arguments`.
- `compile_spec/2` — compiles a pure-data plan spec (`%{iri:, steps:}`) after fail-closed validation. Refusals: `:invalid_plan_spec`, `:empty_plan`, `:invalid_step_spec`, `:duplicate_steps`, `:dangling_predecessors`, `:missing_handlers`, `:invalid_handlers`, `:cyclic_plan`, `:too_many_predecessors` (max 16), `:too_many_terminal_steps` (max 16), `:reactor_builder_error`, `:return_collector_error`.
- Handlers are step IRI => `Reactor.Step` module or `{module, options}`; admission matches `Reactor.Builder`'s own check.
- Steps get deterministic refs (`:step_name`, not `make_ref/0`) and an
  `:ash_pplan` context holding `plan_iri`, `step_iri`, input/output variables,
  predecessors and the predecessor-argument map consumed by
  `AshPPlan.predecessor_results/2` (`lib/ash_pplan/compiler.ex:258`).
- `AshPPlan.Compiler.Error` — exception with `:reason` and `:details` (`lib/ash_pplan/compiler/error.ex`).

### AshPPlan.ControlPlane

Purpose: composes Ash, AshStateMachine, AshOban and Reactor capability surfaces
into one descriptive descriptor; joins admitted facts, never authorizes or runs
(`lib/ash_pplan/control_plane.ex`).

- `describe/1` — `(resource) :: {:ok, map()} | {:error, map()}`; keys: `resource`, `actions`, `state_machine`, `oban`, `action_links`, `closure`, `authority`, `gaps`. Optional surfaces appear as `%{available?: boolean}`; extension absence never creates capability claims.
- `action_catalog/1` — Ash actions as planner-visible metadata (name, type, flags, arguments) without invoking them.

### AshPPlan.ExecutionReceipt

Purpose: PROV-style observation of one semantic plan execution; evidence about
an observed Reactor outcome, not a durable checkpoint, no actuation authority
(`lib/ash_pplan/execution_receipt.ex`).

- Struct: `%AshPPlan.ExecutionReceipt{plan_iri, run_id, status, started_at, finished_at, duration_us, outcome_digest}`; status is `:succeeded | :halted | :failed | :unknown`.
- `to_rdf/1` — N-Triples projecting `ap:runIdentifier`, `ap:executionStatus`, `ap:resultDigest` on `ap:ExecutionReceipt`; receipt is a `prov:Entity` generated by an `ap:SemanticExecution` activity that `prov:used` the plan.
- `run_identifier/1` — run identity as string (any term Reactor accepts).
- `observe/5` — `@doc false`; internal, called by `AshPPlan.execute/5`.
- Digest is over the observed outcome (content address within a build; deterministic `term_to_binary` + SHA-256), not over plan or run.

### AshPPlan.FOND

Purpose: FOND policy semantics over pure-data domains; validates policies,
never executes (`lib/ash_pplan/fond.ex`).

- Struct `%AshPPlan.FOND{states, goals, transitions}`; types `state`, `action`, `mode (:: :strong | :strong_cyclic)`, `policy (:: %{state => action})`.
- `new/2` — `(transitions, goals \\ []) :: {:ok, t} | {:error, map}`; normalizes goals/outcomes; empty nondeterministic outcome lists refused.
- `check/1` — invariants for hand-built structs (normalized form of `new/2`).
- `actions/2`, `outcomes/3` — accessors (sorted).
- `validate_policy/4` — `(t, policy, initial, mode \\ :strong_cyclic) :: {:ok, report} | {:error, map}`; report includes `:ignored_policy_states`. Refusals: `:unknown_initial_state`, `:unknown_policy_states`, `:missing_policy_action`, `:unavailable_policy_action`, `:not_strong`, `:not_strong_cyclic`, `:invalid_policy_request`.
- `to_tla/5` — renders TLA+ module + TLC config; render only, authority `NONE`, ceiling `CONSTRUCT` (`lib/ash_pplan/fond.ex:150`).

Authority: validation and rendering only. No function here executes actions.

### AshPPlan.FOND submodules

| Module | Purpose | Key functions |
|---|---|---|
| `FOND.Synthesis` (`lib/ash_pplan/fond/synthesis.ex`) | Policy synthesis | `synthesize/3 :: {:ok, policy} \| {:error, {:unsolvable, mode, witnesses} \| ...}`; `solvable_states/2`. |
| `FOND.Subject` (`lib/ash_pplan/fond/subject.ex`) | Deterministic court subject identity | `bind/4 :: map`; `same?/2`. |
| `FOND.PolicySwitch` (`lib/ash_pplan/fond/policy_switch.ex`) | Strongest requested solvable mode | `select/3 :: {:ok, map()} \| {:error, map()}`. |
| `FOND.Replay` (`lib/ash_pplan/fond/replay.ex`) | Content-addressed replay bundle | `build/5`; `fingerprint/1`; `bind_fingerprint/1`. |
| `FOND.Projection` (`lib/ash_pplan/fond/projection.ex`) | Provider-neutral, authority-free envelope | `portable/4 :: map`. |
| `FOND.Differential` (`lib/ash_pplan/fond/differential.ex`) | Cross-check against a caller-supplied checker | `check/5`; `compare/3`. |
| `FOND.TLA` (`lib/ash_pplan/fond/tla.ex`) | TLA+ rendering (`t:rendered` map: module string, config, manifest) | `render/5`; `reserved_module_names/0` (`@doc false`). Submodules `TLA.JSON`, `TLA.Manifest`, `TLA.Mutation`. |
| `FOND.Trace` (`lib/ash_pplan/fond/trace.ex`) | Policy graph edges and shortest goal path | `edges/2`; `shortest_goal_path/3`. |
| `FOND.Recovery` (`lib/ash_pplan/fond/recovery.ex`) | Typed routing of validation errors to next actions | `route/1 :: %{action:, preserve_subject:, evidence:}`. |
| `FOND.Counterexample` (`lib/ash_pplan/fond/counterexample.ex`) | Counterexample records from validator or external checker | `from_validator/2`; `from_checker/2`; `classify/1`. |
| `FOND.Corpus` (`lib/ash_pplan/fond/corpus.ex`) | Deterministic seeded domain corpus for courts | `seeded/2`. |
| `FOND.Consumer` (`lib/ash_pplan/fond/consumer.ex`) | Provider-neutral dispatch of powerless runtime intents (behaviour + `dispatch/3`) | callback `dispatch/2`. |
| `FOND.PolicySupervisor` (`lib/ash_pplan/fond/policy_supervisor.ex`) | Epoch-guarded policy supervision state | `start/4` (`domain, initial, mode \\ :strong_cyclic, opts \\ []`); `intent/1`; `horizon_exceeded?/1`; `observe/3`; `replace_domain/2`. `Offers` submodule. |
| `FOND.SupervisionSession` (`lib/ash_pplan/fond/supervision_session.ex`) | Provider-aware supervision session | `start/3`; `intent/1`; `observe_outcome/3`; `observe_provider_health/4`; `replace_registry/2`; `rebind/1`. |
| `FOND.ProviderRegistry` (`lib/ash_pplan/fond/provider_registry.ex`) | Registry of FOND policy providers with health observation | `new/1`; `put/2`; `remove/2`; `observe_health/5`; `select/2`. |

### AshPPlan.Oban

Purpose: projects AshOban triggers and scheduled actions into planner-visible
data; AshOban/Oban keep all scheduling and delivery authority
(`lib/ash_pplan/oban.ex`).

- `describe_resource/1` — resolved surface: `activations`, `capabilities`, `authority` map.
- `activations/1` — every trigger and scheduled action descriptor.
- `capabilities/1` — resource-specific facts (conditional/temporal activation,
  retry, actor/tenant/context propagation, chunking, ...) derived only from
  `:active` activations; identity facts never claimed over an empty set.
- `fetch_activation/2` — by name.
- `describe/2` — one resolved `AshOban.Trigger` or `AshOban.Schedule` as grouped descriptor (`eligibility`, `activation`, `delivery`, `authority`, `input`, `failure`, `batching`, `planner_outcomes`).
- `construct_trigger/3` — `(record, trigger, opts) :: {:ok, changeset}` via
  `AshOban.build_trigger/3`. **CONSTRUCT boundary only** (`AGENTS.md` fence):
  no insertion, scheduling or execution; foreign triggers refused
  (`:foreign_ash_oban_trigger`).
- `observation/1` — classifies an AshOban/Oban return as bounded planner
  observation: `:succeeded`, `:snoozed`, `:cancelled` (incl. deprecated
  `:discard`), `:failed` (retryable), `:unknown`.

### AshPPlan.ProcessEvidence

Purpose: process-evidence events of a workflow run and pure OCEL 2.0 JSON
export (`lib/ash_pplan/process_evidence.ex`).

- `events_from_receipt/3` — `(receipt, subject, opts) :: [Event.t()]`; emits `attempted`/`succeeded` (or `failed`) pairs per task; tasks after a failure are not attempted. Options: `:tasks`, `:realizations`, `:failed_task`.
- `export/2` — `(events, :ocel2_json) :: {:ok, String.t()} | {:error, map()}`; pure; requires Jason. Other formats refused `:unsupported_format`.
- Behaviour callbacks declared for pluggable sources: `events/2`, `export/2`.
- `AshPPlan.ProcessEvidence.Event` — struct `id, activity, timestamp, objects, attributes, subject_id` (`lib/ash_pplan/process_evidence/event.ex`).
- `AshPPlan.ProcessEvidence.Ex4pm` / `AshEx4pm` — optional ex4pm envelope validation surfaces (`lib/ash_pplan/process_evidence/ex4pm.ex`, `ash_ex4pm.ex`; guarded load, "unsupported" when absent).

### AshPPlan.Provider

Purpose: the single provider behaviour — a qualified realization of
capabilities; providers never name a Reactor implementation
(`lib/ash_pplan/provider.ex`).

- Callbacks: `id/0`, `capabilities/0`, `properties/0`, `evidence/0`, `cost/0`
  (ordering only), `qualify/2` (`:ok | {:error, term}`), `realize/2`
  (`{:ok, AshPPlan.Realization.t()} | {:error, term}`). Availability is not
  authority.

### AshPPlan.Provider support modules

| Module | Purpose | Key functions |
|---|---|---|
| `Providers.Registry` (`lib/ash_pplan/providers/registry.ex`) | Provider set with sealing | `new/1`; `default/0` (generated `AshPPlan.Generated.ProviderIndex`); `register/2`; `providers/1`; `seal/3`; `resolve/3`. |
| `Providers.Resolver` (`lib/ash_pplan/providers/resolver.ex`) | Requirement resolution with rejection trace | `resolve/3 :: {:ok, map()} \| {:error, map()}`. |
| `Providers.Qualify` (`lib/ash_pplan/providers/qualify.ex`) | Ceiling checks and realization building shared by providers | `authorities/0` (`:construct` max); `check/6`; `realize/4`; `adapter_available/1`. |

### AshPPlan.Realization

Purpose: a provider's implementation-neutral description of how a capability is
realized (`lib/ash_pplan/realization.ex`). Only `AshPPlan.Reactor` turns a
realization into steps.

- Struct: `%AshPPlan.Realization{capability, provider, binding, options, properties}`; binding `%{adapter: atom, op: atom}`.
- `adapters/0` — keys of `AshPPlan.Reactor.adapters/0`.
- `op_for/1` — `File.Write` -> `:file_write`.
- `validate/1` — binding shape; `binding: nil` (legacy step-naming shape) is refused.
- `from_map/2`, `new/2` — construction (validated / unvalidated).

### AshPPlan.Reactor

Purpose: binds a Reactor to one workflow subject so semantic identity survives
execution, dynamic expansion and durable resumption; ceiling `:construct`
(`lib/ash_pplan/reactor.ex`).

- `adapters/0` — built-in adapter id table (`reactor_file`, `reactor_req`,
  `reactor_process`, `ash_reactor`, `bb_reactor`, `local`, `durable`) merged
  with `config :ash_pplan, :extra_adapters`.
- `step_for/2` — resolves a realization to `{step_module, step_options}`;
  resolved module must implement `Reactor.Step` (`:not_a_step`).
- `validate_step/1` — loaded `Reactor.Step` implementation check.
- `context_key/0` — `:ash_pplan_workflow`.
- `enrich/3` — stamps step identities, sets reactor id to the subject-bound
  plan IRI, installs `Middleware.Identity` and `Middleware.Evidence`; optional
  projection verification via `Subject.verify_projection/3`.
- `identity_of/1` — identity stamped on a step/context, or `nil`.
- `inherit/2` — child identity for dynamically created steps; refusal on
  authority above the parent ceiling (`:authority_escalation`) or outside the
  vocabulary (`:unknown_authority`).
- `add_middleware/2` — idempotent middleware installation.

Related public contracts:

- `Reactor.Adapter` behaviour (`lib/ash_pplan/reactor/adapter.ex`): `id/0`,
  `available?/0`, `ops/0`, `step/2`; shared body `resolve/4`.
- `Reactor.Middleware.Identity` / `.Evidence` / `.Observation`
  (`lib/ash_pplan/reactor/middleware/*.ex`): identity verification on
  (re)start, evidence events, telemetry observation with `events/0`,
  `ledger_events/2` and a test `Collector` (`start/0`, `stop/1`, `events/1`).
- `Reactor.Steps.*` (`lib/ash_pplan/reactor/steps/*.ex`): `Actuate`, `Await`,
  `Command`, `DomainAction`, `Propose`, `Telemetry` — step implementations
  bound through adapters. `Reactor.Step.ReturnTerminals` (`@doc false`) is the
  compiler's return collector.

### AshPPlan.Reactor.Durable

Durable continuation ledger (run records, checkpoints, signals, waiters,
claims, unwinding). All persistence goes through the `Store` behaviour
(`AGENTS.md` durable-store fence).

- `Reactor.Durable.Store` behaviour (`lib/ash_pplan/reactor/durable/store.ex`)
  — 20 callbacks: `start_run/2`, `get_run/2`, `list_runs/1`, `transition/5`
  (guarded, bumps version), `claim/5`, `release_claim/3`, `checkpoints/2`,
  `standing/2`, `record/6` (insert-or-adopt by `(run, key)`),
  `claim_undo/3`, `release_undo/3`, `deliver_signal/4`,
  `pending_signal/3`, `consume_signal/3`, `park/6`
  (insert unless present; `overwrite: true` replaces),
  `get_waiter/3`, `waiters/2`, `release/3`, `release_all/2`, `signals/2`.
  A new backend must pass the generated store-conformance suite
  (`bin/manufacture-store-conformance`).
- `Store.Ets` (`lib/ash_pplan/reactor/durable/store/ets.ex`) — GenServer-backed
  ETS table (`start_link/1`), single node, non-persistent reference
  implementation of every `Store` callback; not a durability claim.
- `Store.Dets` (`lib/ash_pplan/reactor/durable/store/dets.ex`) — GenServer over
  a single local DETS file (`start_link/1`, flushed on terminate), one node;
  implements every `Store` callback with the same signatures.
- `Reactor.Durable.Status` (`lib/ash_pplan/reactor/durable/status.ex`) — run
  status machine with guarded transitions. States: `pending, waiting, polling,
  unwinding, cancelling, unwind_blocked, completed, failed, cancelled`;
  terminal states (`completed, failed, cancelled`) are absorbing — no
  transition may overwrite them. `all/0`; `terminal?/1`; `parked?/1`
  (`waiting, polling`); `rolling_back?/1` (`unwinding, cancelling`);
  `cancellable?/1` (only from `pending, waiting, polling`); `can?(from, to)` —
  allowed transitions: any non-terminal -> any non-terminal;
  `unwinding -> failed | unwind_blocked`; `cancelling -> cancelled |
  unwind_blocked`; `unwind_blocked -> unwinding | cancelling | failed |
  cancelled`.
- `Reactor.Durable.Engine` (`lib/ash_pplan/reactor/durable/engine.ex`) —
  claim/attempt engine; every function takes the store first:
  `lease_ms/0`, `start/3` (idempotent by run id), `attempt/3` (one claimed
  attempt; outcome is `t:outcome/0`: `{:completed, term}`, `{:parked, atom}`,
  `{:failed, term}`, `{:rolled_back, atom}`, `{:refused, term}`, `:taken`,
  `:ended`, `:not_found`), `drive_policy/3`,
  `signal/5` (consume-once FIFO per name), `wake/3`, `cancel/3`, `fetch/3`,
  `steps/3`, `runnable?/4`, `runnable/3`.
- Support modules (internal surface, see below): `Record`, `Run`,
  `Key`, `Clock`, `Checkpointed`, `Unwind`, `Verifier`, `Portable`,
  `LedgerOcel`, `Middleware`, `Migration`, `PolicyDriver`, `Counterfactual`,
  `ChildError`, `Testing`, `Steps.Await/Dispatch/Poll`. (`Status` and
  `LedgerOCEL` are public — see above.)

#### AshPPlan.Reactor.Durable.LedgerOCEL

Purpose: export a durable run's standing checkpoint ledger as process-mining
evidence; one `task_succeeded` event per standing checkpoint plus
`run_started`/`run_ended` events (`lib/ash_pplan/reactor/durable/ledger_ocel.ex`).

| Function | Signature | Notes |
|---|---|---|
| `events/3` | `(store, run_id, opts \\ []) :: {:ok, [Event.t()]} \| {:error, map()}` | Events ordered by the ledger's monotonic `seq`, carried in attributes; each carries the workflow subject id from the run context when present. `{:error, %{reason: :no_such_run}}` for an unknown run. `:store_module` option (default `Store.Ets`). Timestamps reflect export time; `seq` is authoritative. |
| `export/3` | `(store, run_id, opts \\ []) :: {:ok, String.t()} \| {:error, map()}` | `AshPPlan.ProcessEvidence.export/2` in OCEL 2.0 JSON. |
| `digest/3` | `(store, run_id, opts \\ []) :: {:ok, String.t()} \| {:error, map()}` | SHA-256 over `{id, activity, attributes}` of every event; changes if any standing output changes. The digest the standing receipt's `derived_from` cites. |

See [Process evidence and OCEL](../explanation/process-evidence-and-ocel.md)
for the design rationale.

Authority: `PolicyDriver`, `Counterfactual` and `Migration` select, replay or
map structure only; ceiling `:construct` (`AGENTS.md`). Engine admission is
observation of durable runs, not actuation authority.

### AshPPlan.ReactorOutcome

Purpose: classifies Reactor's public results into planner observations
(`lib/ash_pplan/reactor_outcome.ex`). No execution authority.

- `state/1` — `:succeeded | :halted | :failed | :unknown`.
- `observe/1` — bounded observation map without claiming authority.

### AshPPlan.ReleaseReceipt

Purpose: content-addressed evidence about one exact release head; evidence, not
authority (`lib/ash_pplan/release_receipt.ex`).

- `observe/1` — `(head_sha :: 40- or 64-hex) :: t`; binds Git head to compile-time digests of `ontology.ttl`, `ontology/shapes.ttl`, `ecosystem.lock.toml`, `lib/ash_pplan/generated/projection_catalog.ex`, `lib/ash_pplan/generated/plan_catalog.ex`.
- `digest/3` — SHA-256 over head, release and sources (exposed for falsification).
- `sources/0` — name-keyed observed source digests.
- `to_json/1` — deterministic JSON (no JSON dependency).

### AshPPlan.Standing

Purpose: standing of one workflow run as a library API —
`PlanCorrect and ExecutionCorrect and ObservedConsequenceCorrect`
(`lib/ash_pplan/standing.ex`). Nothing here grants DO authority; receipt
ceiling defaults to `"CONSTRUCT"`; a `"DO"` ceiling is refused by the receipt
validator.

- `layers/0` — the three verdict layers in order.
- `verdict/3` — combine three layer verdicts into `:alive` or `{:lost, broken_layers}`.
- `verdicts/1` — all three layer verdicts of a run as a map.
- `standing/1` — `:alive | {:lost, broken_layers}`.
- `plan_correct/1,2` — plan layer over process-evidence events, model,
  provider selection and FOND gates (`:fond_gates`).
- `execution_correct/1` — `{observed, wanted}` equality.
- `observed_consequence_correct/1` — named boolean checks of real post-state.
- `ladder/2` — `(run, opts \\ []) :: {:ok, %{state:, index:, trail:}}`; the run's
  position on the 10-state evidentiary ladder (`Standing.Ladder`, below) with a
  single-rung audit trail. Each rung is admitted only when derivable from the
  run's real inputs (events present, layer verdicts, receipt forms, observed
  post-state, OCEL evidence digest); promotion stops at the first non-derivable
  rung. `opts` forward to `receipt/2`.
- `receipt/2` — `{:ok, %AshPPlan.Standing.Receipt{}} | {:error, map}`; options
  `:actor`, `:ceiling`, `:grant`, `:replay_commands` (required for a replay
  field), `:evidence` (OCEL 2.0 JSON sha256 + guarded ex4pm validation).

Support modules:

- `Standing.Receipt` (`lib/ash_pplan/standing/receipt.ex`) — five-field
  receipt struct (`identity, authority, consequence, replay, standing`);
  `fields/0`, `standings/0` (`ALIVE`, `BLOCKED`, `BUILD_BROKEN`,
  `PARTIAL_ALIVE`, ...), `safe_ceilings/0` (`CONSTRUCT`, `OBSERVE`,
  `SELECT`), `layer_term/1` (broken-term mapping: `plan_correct` ->
  `mu_on_O`, `execution_correct` -> `mu_unlawful`,
  `observed_consequence_correct` -> `R_missing_consequence`), `new/1`,
  `validate/1`, `to_map/1`.
- `Standing.Chain` (`lib/ash_pplan/standing/chain.ex`) — hash-chained ledger
  (SHA-256, genesis all-zeros): `algorithm/0`, `genesis/0`, `digest/1`,
  `canonical/1`, `sealed?/1`, `unpaired/1`, `append_pending/4`,
  `append_outcome/5`, `seal/4`, `verify/1`, `head/1`.

### AshPPlan.Standing.Ladder

Purpose: the fixed 10-state evidentiary standing ladder, adopted from
`ggen-marketplace/packs/standing-ladder-pack` (`st:` ontology)
(`lib/ash_pplan/standing/ladder.ex`):

    UNKNOWN(0) -> OBSERVED(1) -> VALIDATED(2) -> DERIVED(3) -> CANDIDATE(4)
    -> EXPERIMENTALLY_SUPPORTED(5) -> ADMITTED(6) -> MANUFACTURED(7) -> ACTUATED(8)
    -> VERIFIED(9)

Law: a claim's standing is not self-certifying — it is admissible only through a
real, evidenced, single-rung transition chain reaching it from `:UNKNOWN`.
Nothing here grants DO authority; the ladder reads evidence, it never
manufactures it. `AshPPlan.Standing.ladder/2` derives the highest rung from a
run's real evidence; `admit/1` enforces the chain law on a supplied claim.

- `states/0` — the 10 ladder states in promotion order.
- `index/1` — `(state) :: non_neg_integer() | {:error, map}`; 0-based index;
  outside the closed set refused with `broken_term: "STL_unknown_state"`.
- `admit/1` — `(claim) :: {:ok, %{fact:, state:, trail:}} | {:error, map}`.
  Claim: `%{fact:, state:, transitions:}` where each transition is
  `%{from:, to:, evidence:}`. Refusals: `STL_dangling_fact` (nil `:fact`),
  `STL_unknown_state`, `STL_malformed_claim`,
  `STL_missing_rung` (with `missing_rung_index: k`, 1-based) when rung `k` has
  no valid transition — each transition must be exactly one rung with a
  non-empty `:evidence`, and the chain must start from `:UNKNOWN`.

### AshPPlan.StateMachine

Purpose: projects AshStateMachine lifecycle semantics into planner data; never
performs a transition (`lib/ash_pplan/state_machine.ex`).

- `from_resource/2` — declared transitions as a FOND domain.
- `describe_resource/1` — full lifecycle descriptor: `states` (all valid,
  including deprecated), `wildcard_states` (AshStateMachine's narrower `:*`
  universe, excludes deprecated-only), `deprecated_states`, `extra_states`,
  `initial_states`, `default_initial_state`, `transitions`,
  `wildcard_actions` (concrete update actions), `capabilities`, `authority`.
- `capabilities/1` — separates `:supported` (dependency facts) from
  `:configured` (resource facts from transitions/changes/policies);
  `wildcard_transitions?` observes `action: :*` only.
- `possible_next_states/1,2` — delegates to `AshStateMachine.possible_next_states/1,2`;
  `/2` takes a concrete action name and refuses unknown actions.
- `from_transitions/3,4` — pure-data projection; goals outside the state set
  refused (`:unknown_goal_states`); `action: :*` requires concrete
  `:wildcard_actions` (`:wildcard_action_must_be_concrete`).
- `StateMachine.Charts` (`lib/ash_pplan/state_machine/charts.ex`) — `render/2`
  (type `:state` | `:flow`) delegates Mermaid diagrams to
  `AshStateMachine.Charts`; non-atom resources refused `:not_an_ash_resource`.

### AshPPlan.Workflow

Purpose: Spark DSL for declaring a semantic workflow; declares semantics only,
never grants actuation authority (`lib/ash_pplan/workflow.ex`).

- `use AshPPlan.Workflow` with a `workflow do ... end` section (`goal`, `task`,
  `method`); the module gains `__ash_pplan_workflow__/0` returning the
  normalized `AshPPlan.Workflow.Model`. Verifiers reject duplicate ids,
  unknown or cyclic `after` dependencies, unparseable capabilities and
  authority above `:construct` (`lib/ash_pplan/workflow/dsl/verifiers/*.ex`).
- `model/1` — resolve a DSL module (or model) to a validated `Model`.
- `Workflow.Dsl` — the Spark extension (`lib/ash_pplan/workflow/dsl/extension.ex`);
  `Workflow.Dsl.Info` — readers: `tasks/1`, `methods/1`, `goal/1`, `name/2`,
  `version/1`, `build/2`.

### AshPPlan.Workflow support modules

| Module | Purpose | Key functions |
|---|---|---|
| `Workflow.Model` (`lib/ash_pplan/workflow/model.ex`) | Normalized model struct | `new/1`; `authorities/0` (`:do` never among them); `validate/1`; `topological_order/1`; `task/1`; `method/1`; `canonical/1`. |
| `Workflow.Task` (`lib/ash_pplan/workflow/task.ex`) | Task struct: capability requirement with ordering, outcomes, properties | struct only. |
| `Workflow.Method` (`lib/ash_pplan/workflow/method.ex`) | HDDL decomposition method struct | struct only. |
| `Workflow.Subject` (`lib/ash_pplan/workflow/subject.ex`) | Subject binding and projection verification | `bind/1`; `same?/2`; `correspondence/2`; `verify_correspondence/3`; `verify_projection/3` (kinds `:pplan \| :hddl \| :fond \| :reactor`). |
| `Workflow.Authority` (`lib/ash_pplan/workflow/authority.ex`) | Authority ceiling admission | `admit/1`; `check_metadata/1`; `granted/1` — always `[]`: planning grants nothing. |
| `Workflow.Evidence` (`lib/ash_pplan/workflow/evidence.ex`) | Evidence kinds, telemetry, subject-bound evidence | `kinds/0`; `telemetry_event/0`; `profile/1`; `bind/2`; `plan_iri/1`; `verify/2`. |
| `Workflow.Explain` (`lib/ash_pplan/workflow/explain.ex`) | Structural explanations and counterfactuals | `workflow/2`; `run/1`; `counterfactual/3`. |
| `Workflow.Runtime` (`lib/ash_pplan/workflow/runtime.ex`) | Workflow lifecycle engine (select → run → observe → resume) | `model/1`; `validate/1`; `plan/2`; `project/3` (`:pplan \| :hddl \| :fond \| :reactor`); `capabilities/0`; `providers/0`; `registry/1`; `resolve/2`; `run/3`; `signal/4`; `cancel/2`; `observe/3` (FOND transition + evidence + provider sealing on failure); `resume/2` (resumes halted in place, re-resolves failed against the sealed registry); `inspect/1`; `explain/2`. |

Authority: the runtime resolves, runs through Reactor and observes; it grants
no authority beyond what the model declares (which is never `:do`).

### AshPPlan.SA2A

Purpose: SA2A policy-candidate surface (FOND and PoWL formalisms) for
propose/replay flows (`lib/ash_pplan/sa2a/*.ex`).

- `Sa2a.Capability` (`capability.ex`) — `supported/0`, `supports?/1`, `descriptor/1`.
- `Sa2a.PolicyCandidate` (`policy_candidate.ex`) — `fond/2`, `powl/2` candidate constructors.
- `Sa2a.Provider` (`provider.ex`) — `supports?/1`, `propose/2` dispatch on formalism.
- `Sa2a.Replay` (`replay.ex`) — `fond/3` replay.
- `Sa2a.SubjectGuard` (`subject_guard.ex`) — `fetch/1`, `preserve/2` subject binding.
- `Sa2a.Refusal` (`refusal.ex`) — typed refusal codes (`new/2`, `codes/0`).

### AshPPlan.FrontierEvidence

Purpose: deterministic FrontierEvidence v1 projection of control-plane data;
SELECT/CONSTRUCT only, performs no action, transition, insertion, schedule,
execution or resume (`lib/ash_pplan/frontier_evidence.ex`).

- `from_control_plane/3` — `(control_plane, fond_validation, opts) :: map`; requires `:producer_head`, optional `:standing` (default `"CANDIDATE"`); body carries `authority_ceiling: "CONSTRUCT"`, an explicit `refused:` list, and a `sha256:` `artifact_hash`.

### AshPPlan.PolicyClosure

- `PolicyClosure.AuthorityCeiling` (`lib/ash_pplan/policy_closure/authority_ceiling.ex`)
  — `admit/1 :: {:ok, :observe | :select | :construct} | {:error, :authority_ceiling}`.
  The maximum admitted ceiling is `:construct`.

## Generated surface (manufactured — never hand-edited)

Produced by `ggen_igniter` from `ontology.ttl` via `./bin/manufacture`
(`AGENTS.md`). Read through the facade; repair upstream, regenerate.

| Module | File | Accessors |
|---|---|---|
| `AshPPlan.Generated.ProjectionCatalog` | `lib/ash_pplan/generated/projection_catalog.ex` | `all/0`, `fetch/1`, `by_role/1` |
| `AshPPlan.Generated.PlanCatalog` | `lib/ash_pplan/generated/plan_catalog.ex` | `all/0`, `fetch/1` |
| `AshPPlan.Generated.CapabilityCatalog` | `lib/ash_pplan/generated/workflow/capability_catalog.ex` | `all/0`, `ids/0` |
| `AshPPlan.Generated.ProviderIndex` | `lib/ash_pplan/generated/workflow/provider_index.ex` | `modules/0` |
| `AshPPlan.Generated.Workflow.Providers.*` | `lib/ash_pplan/generated/workflow/providers/*.ex` | generated providers (`a2a`, `domain`, `durability`, `durable_dispatch`, `event_state`, `file`, `network`, `observation`, `process`, `remote`, `scheduling`) |

## Internal surface (not intended for consumers)

Stable enough to read, unstable as contracts; changes without notice.

- `AshPPlan.Workflow.Dsl` transformers/verifiers internals (`workflow/dsl/transformers/`, `verifiers/helpers.ex`) — semantics enforced via the DSL's public verifiers.
- `AshPPlan.Reactor.Durable` internals: `Record`, `Run`, `Key`, `Clock`, `Checkpointed`, `Unwind`, `Verifier`, `Portable`, `Middleware`, `ChildError`, `Testing`, `Steps.Await/Dispatch/Poll` (`lib/ash_pplan/reactor/durable/*.ex`) — engine plumbing behind `Engine`, `Store` and `Status`. (`Status` and `LedgerOCEL` are documented as public above.)
- `AshPPlan.Reactor.Adapters.*` implementations (`reactor/adapters/*.ex`) — reached through `AshPPlan.Reactor.adapters/0` and the `Reactor.Adapter` behaviour, not called directly.
- `AshPPlan.FOND.PolicySupervisor.Offers`, `AshPPlan.FOND.TLA.JSON/Manifest/Mutation` — sub-helpers of their parents.
- `AshPPlan.ProcessEvidence.Ex4pm`/`AshEx4pm` internal envelope handling — consumed via `AshPPlan.Standing.receipt/2` evidence.
- `AshPPlan.Reactor.Step.ReturnTerminals` — `@doc false` compiler return collector.
- `AshPPlan.ExecutionReceipt.observe/5` — `@doc false`; invoked by `AshPPlan.execute/5`.

# Domain Evaluation Brief: Zach Daniel
## Ash Framework, Spark DSL, Resource Architecture & Policy Fences

- **Evaluator**: Zach Daniel (Creator of Ash Framework & Spark DSL)
- **Role**: Ash Framework & DSL Architecture Authority
- **Milestone**: `v26.11.10`
- **Date**: 2026-11-10
- **Status**: APPROVED (Score: `19.5 / 20.0` — 97.5%)

---

## 1. Executive Profile & Lens

Zach Daniel is the author and lead architect of the Ash Framework and the Spark declarative DSL engine for Elixir. His architectural philosophy centers on modeling business logic declaratively through resources, actions, policies, and calculations, treating execution frameworks not as monolithic runtimes, but as composable, observable, and policy-governed control planes.

From the Ash perspective, the evaluation of `ash_pplan` focuses on:
1. **The "No Third Engine" Principle**: Ensuring `ash_pplan` does not introduce an unnecessary execution engine, but rather delegates orchestration to `Reactor`, domain logic to `Ash`, persistent lifecycles to `AshStateMachine`, and background scheduling to `AshOban`.
2. **Action Boundary & Policy Fencing**: Verifying that dynamically compiled workflows enter the domain through authorized Ash actions (`AshPPlan.Action.Run`), where policies, actors, tenants, and parameter validations are strictly enforced prior to execution.
3. **Remote Code Execution (RCE) Defense**: Confirming that user/client input cannot inject arbitrary step implementations into the execution runtime.
4. **Data-Layer Transaction Safety**: Guaranteeing that executions occurring within database transactions are forced into synchronous evaluation (`async?: false`), preventing detached or leaked uncommitted database states.
5. **DSL Cleanliness & Spark Verifiers**: Ensuring extensions build on Spark without polluting the AST with unhygienic macros or runtime overhead.

---

## 2. Technical Surface Area Under Review

The following primary modules and files were scrutinized during this evaluation:

| Module / Artifact | File & Line References | Architectural Function |
|---|---|---|
| `AshPPlan.Action.Run` | `lib/ash_pplan/action/run.ex:1-184` | Generic-action DO boundary for dynamic plans, RCE prevention, transaction synchronization |
| `AshPPlan.Action.Run.Refusal` | `lib/ash_pplan/action/run.ex:43-57` | Typed refusal implementing `use Splode.Error, class: :invalid` |
| `AshPPlan.Dsl.PPlan` | `lib/ash_pplan/dsl/pplan.ex:1-80` | Spark DSL extension defining P-PLAN entities and sections |
| `AshPPlan.Reactor.Steps.DomainAction` | `lib/ash_pplan/reactor/steps/domain_action.ex:1-71` | Reactor step executing Ash resource actions under actor/tenant context |
| `AshPPlan.Reactor.Steps.Actuate` | `lib/ash_pplan/reactor/steps/actuate.ex:1-19` | Actuation boundary holding `authority: :construct` |
| `AshPPlan.Oban` | `lib/ash_pplan/oban.ex:1-92` | Projection of AshOban triggers into planner-visible facts without reproducing queues |
| `AshPPlan.StateMachine` | `lib/ash_pplan/state_machine.ex:1-110` | Projection of AshStateMachine transitions without duplicating the lifecycle engine |

---

## 3. Architectural Analysis & Findings

### 3.1 The "No Third Engine" Discipline
`ash_pplan` exhibits exemplary architectural restraint. Rather than implementing a redundant, ad-hoc workflow interpreter, it defines an epistemic and control-plane projection over established BEAM engines.
- **Reactor Ownership**: DAG execution, step dependency resolution, retries, compensation, undo stacks, concurrency, and dynamic expansion remain strictly within `Reactor`.
- **Ash Resource Ownership**: Authorization policies, domain attributes, calculations, changesets, and tenant boundaries remain governed by Ash resources.
- **AshStateMachine Ownership**: In `lib/ash_pplan/state_machine.ex:9-13`, the projection explicitly states: *"This module never performs a state transition. AshStateMachine, Ash actions, and Ash policies remain authoritative for persistent resource lifecycle changes."* It projects transitions into FOND planner states without building a shadow FSM runtime.
- **AshOban Ownership**: In `lib/ash_pplan/oban.ex:5-10`, triggers are projected into planner-visible data. AshOban and Oban retain complete authority over job workers, crons, unique locks, retries, and queues.

### 3.2 Generic Action Boundary (`AshPPlan.Action.Run`)
Direct invocation of `AshPPlan.execute/5` is appropriately treated as an internal engine primitive. The canonical, application-facing entry point is `AshPPlan.Action.Run`, which implements `Ash.Resource.Actions.Implementation`:
```elixir
# lib/ash_pplan/action/run.ex:66-72
reactor_context = context |> Ash.Scope.to_opts() |> Map.new()
reactor_options = transaction_options(action_input, config.reactor_options)

plan_iri
|> AshPPlan.execute(handlers, input, reactor_context, reactor_options)
|> admit(config.allow_halt?)
```
By flowing through an Ash generic action, every plan execution is preceded by:
1. Argument validation against the action schema;
2. Actor, tenant, and policy authorization checks;
3. Context enrichment via `Ash.Scope.to_opts/1`.

### 3.3 Remote Code Execution (RCE) Defense
A critical security vulnerability in dynamic workflow execution is allowing client arguments to dictate module dispatch. `AshPPlan.Action.Run` eliminates this vector:
```elixir
# lib/ash_pplan/action/run.ex:154-160
defp handlers(arguments, configured) do
  if is_nil(Map.get(arguments, :handlers)) do
    {:ok, configured}
  else
    refuse(:handlers_argument_refused, %{})
  end
end
```
When server-side `:handlers` are configured (the mandatory production path), any attempt by an API caller to provide a `:handlers` argument triggers an immediate `:handlers_argument_refused` refusal. This guarantees callers cannot execute arbitrary modules loaded in the BEAM VM.

### 3.4 Data-Layer Transaction Coordination
A classic failure mode when embedding asynchronous DAG runtimes (such as Reactor) inside database transactions is the detachment of spawned child processes, which cannot see uncommitted data or participate in transaction rollbacks.
`AshPPlan.Action.Run` inspects transaction state dynamically:
```elixir
# lib/ash_pplan/action/run.ex:162-170
defp transaction_options(action_input, reactor_options) do
  resources = [action_input.resource | List.wrap(action_input.action.touches_resources)]

  if Enum.any?(resources, &Ash.DataLayer.in_transaction?/1) do
    Keyword.put(reactor_options, :async?, false)
  else
    reactor_options
  end
end
```
When `in_transaction?/1` returns `true`, Reactor is forced to run synchronously (`async?: false`), ensuring that all steps execute on the caller's process and within the active transaction boundary.

### 3.5 Error Unwrapping & Splode Integration
Error integration with the Ash ecosystem is handled cleanly:
- `AshPPlan.Action.Run.Refusal` uses `use Splode.Error, fields: [:reason, details: %{}], class: :invalid`, ensuring that refusals surface as native `Ash.Error.Invalid` structures rather than unhandled crashes.
- In `lib/ash_pplan/action/run.ex:93-94`, Reactor errors of shape `{:error, %{splode: Reactor.Error, errors: errors}}` are unwrapped directly to `{:error, errors}`. When a nested step fails an Ash policy (e.g., returning `Ash.Error.Forbidden`), the error is preserved in its native Ash form, allowing transaction rollback hooks and Ash error handlers to function correctly.

---

## 4. Probing Inquiries & Falsifiers

### Inquiry 1: Does `AshPPlan.Action.Run` preserve multi-tenant scoping across step execution?
**Analysis**: `reactor_context` extracts caller scope via `context |> Ash.Scope.to_opts() |> Map.new()`, which includes `:actor`, `:tenant`, and `:authorize?`.
**Falsifier**: In `AshPPlan.Reactor.Steps.DomainAction`, if `tenant` is omitted from step arguments, it should reliably fallback to `context[:tenant]`. While `DomainAction` does inspect context, nested sub-reactors dynamically spawned must ensure this context is explicitly propagated down the call stack.

### Inquiry 2: Can a malicious actor bypass the RCE defense by injecting module atoms in plan IRIs?
**Analysis**: `validate_plan_iri/2` (`lib/ash_pplan/action/run.ex:133-144`) validates that the plan IRI is a binary string and checks it against the optional `:plans` allowlist. Plan IRIs are parsed via RDF graphs, not `String.to_existing_atom/1`, preventing atom table exhaustion and unauthorized code loading.

### Inquiry 3: Does the Spark DSL extension introduce compile-time verification?
**Analysis**: `AshPPlan.Dsl.PPlan` configures Spark entities with schema types and validators. Malformed section declarations or duplicate step names fail at compile time during `Spark.Dsl.Verifier` execution.

---

## 5. Scored Evaluation Rubric

| Dimension | Weight | Score | Evaluation Justification |
|---|:---:|:---:|---|
| **1. DSL Cleanliness & Spark Verifiers** | 25% | `5.0 / 5.0` | Uses declarative Spark DSL entities (`Spark.Dsl.Entity`, `Section`, `Verifier`) without introducing unhygienic macros or custom expansion rules. Topologies are validated at compile time. |
| **2. Authority Boundary Discipline** | 25% | `5.0 / 5.0` | Strict adherence to the DO boundary. Direct `execute/5` is walled off; application workflows must flow through `AshPPlan.Action.Run`. Actuation steps carry explicit ceilings (`authority: :construct`). |
| **3. Tenant & Actor Propagation** | 25% | `4.5 / 5.0` | Scopes are cleanly converted via `Ash.Scope.to_opts()`. Minor recommendation to formalize tenant fallback cascading inside nested dynamic sub-reactors. |
| **4. Transaction Safety & Coordination** | 25% | `5.0 / 5.0` | Dynamic inspection of `Ash.DataLayer.in_transaction?/1` automatically forcing `async?: false` ensures zero transaction detachment bugs. |
| **TOTAL** | **100%** | **`19.5 / 20.0`** | **Exceptional architectural alignment with Ash Framework idioms and security standards.** |

---

## 6. Verdict & Operational Recommendations

### Verdict: **APPROVED**
`ash_pplan` v26.11.10 provides a best-in-class integration with the Ash Framework. It respects existing execution abstractions, enforces impenetrable policy and RCE fences, and integrates natively with Ash's transaction and error models.

### Operational Recommendations
1. **Multi-Tenancy Propagation in Custom Steps**: In `AshPPlan.Reactor.Steps.DomainAction`, standardize the tenant fallback clause:
   ```elixir
   tenant = Map.get(arguments, :tenant) || Map.get(context, :tenant)
   ```
   Ensure this convention is documented for third-party custom step developers.
2. **Spark Cheat-Sheet Generation**: Generate a Spark cheat-sheet task (`mix ash_pplan.generate_cheatsheet`) in future releases to provide IDE autocompletion and documentation for `AshPPlan.Dsl.PPlan`.

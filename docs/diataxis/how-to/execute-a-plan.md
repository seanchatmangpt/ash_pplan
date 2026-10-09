# How to execute a P-PLAN from your application

Goal: run an admitted P-PLAN (a plan compiled from `ontology.ttl` into
`AshPPlan.Catalog.Plan`) from application code, through the Ash action
boundary, and read back an execution receipt.

## Prerequisites

- An Ash application with a domain and at least one resource; you know how to
  define generic actions and call them with `Ash.ActionInput.for_action/3` and
  `Ash.run_action/1`.
- `ash_pplan` in your deps.
- A plan in the catalog. Plans are manufactured from `ontology.ttl` by
  ggen_igniter into `AshPPlan.Catalog.Plan`
  (`lib/ash_pplan/catalog/plan_catalog.ex` — generated file, never edit;
  regenerate with `./bin/manufacture`). List them with `AshPPlan.plans/0`,
  fetch one with `AshPPlan.plan/1`. Each plan carries `iri` and `steps`, and
  each step carries `iri`, `predecessors`, `inputs`, `outputs`.
- A `Reactor.Step` implementation module for every step IRI of the plan. The
  compiler refuses a run whose plan has steps with no handler
  (`:missing_handlers`, `lib/ash_pplan/compiler.ex`).

## 1. Define the action on a resource (preferred path)

Expose a generic action whose implementation is `AshPPlan.Action.Run`
(`lib/ash_pplan/action/run.ex`). Configure handlers and a plan allowlist on the
server — this is the production path, because a caller can never choose which
modules run:

```elixir
action :run_plan, :map do
  argument :plan_iri, :string, allow_nil?: false
  argument :input, :term

  run {AshPPlan.Action.Run,
       plans: ["https://w3id.org/ash-pplan#SubscriptionRenewal"],
       handlers: %{
         "https://w3id.org/ash-pplan#AuthorizePayment" => MyApp.Steps.AuthorizePayment,
         "https://w3id.org/ash-pplan#RenewSubscription" => MyApp.Steps.RenewSubscription
       }}
end
```

Action options (`lib/ash_pplan/action/run.ex` moduledoc and `config/1`):

- `:handlers` — map of step IRI to a `Reactor.Step` module (or
  `{module, options}`). The compiler only admits modules that are loaded and
  implement the behaviour (`lib/ash_pplan/compiler.ex`, `valid_handler?/1`).
- `:plans` — allowlist of plan IRIs. A `:plan_iri` outside it is refused with
  `:plan_not_allowed`.
- `:allow_halt?` — `false` (default): a halted Reactor is refused with
  `:reactor_halted` and rolls back an enclosing transaction. `true`: the halted
  reactor is returned so you can capture it for durable resumption.
- `:reactor_options` — forwarded to `Reactor.run/4`.

If `:handlers` is configured, a caller-supplied `:handlers` argument is refused
with `:handlers_argument_refused` (`lib/ash_pplan/action/run.ex`, `handlers/2`).

Why this boundary: Ash performs argument validation, policy authorization and
actor/tenant setup **before** `AshPPlan.Action.Run` delegates to
`AshPPlan.execute/5` (`lib/ash_pplan/action/run.ex` moduledoc). Repository
doctrine (`AGENTS.md`, "Ash action boundary") names this the preferred
application authority boundary for downstream actuation.

## 2. Call it through Ash

```elixir
plan = "https://w3id.org/ash-pplan#SubscriptionRenewal"

MyApp.PlanResource
|> Ash.ActionInput.for_action(:run_plan, %{plan_iri: plan, input: %{order: 1}})
|> Ash.run_action(actor: actor, tenant: tenant, authorize?: true)
```

This is the same shape exercised by `test/action_run_test.exs` (against
`AshPPlan.Test.PlanRunResource`, defined in
`test/support/semantic_core_fixtures.ex`).

Success returns:

```elixir
{:ok, %{outcome: {:ok, result}, receipt: receipt}}
```

Failure and refusal behavior (`lib/ash_pplan/action/run.ex`, `admit/2`):

- A failed Reactor outcome fails the Ash action as `{:error, errors}`, with the
  `Reactor.Error` unwrapped the way Ash does for Reactor-backed actions, so Ash
  classifies step errors (for example a nested `Ash.Error.Forbidden`) and rolls
  back.
- Refusals are `AshPPlan.Action.Run.Refusal` exceptions (Splode class
  `:invalid`): `:plan_not_allowed`, `:handlers_argument_refused`,
  `:reactor_halted`, `:missing_action_argument`, `:invalid_action_arguments`,
  `:invalid_action_options`, `:unrecognised_outcome`.
- Receipts are returned only for admitted outcomes. To observe a receipt for a
  failure, call `AshPPlan.execute/5` directly (see step 4).

Transaction interaction: if the action runs inside a data-layer transaction
(`transaction? true`), Reactor is forced to `async?: false` so every step
executes inside that transaction (`lib/ash_pplan/action/run.ex`,
`transaction_options/2`).

## 3. Read the execution receipt

`AshPPlan.ExecutionReceipt` (`lib/ash_pplan/execution_receipt.ex`) is a
PROV-style observation of one execution:

| field | meaning |
|---|---|
| `plan_iri` | the plan that ran |
| run_id | run identity (any term Reactor accepts) |
| `status` | `:succeeded`, `:halted`, `:failed`, or `:unknown` |
| started_at, finished_at | wall-clock bounds (DateTime) |
| duration_us | monotonic duration in microseconds |
| outcome_digest | SHA-256 content address of the observed outcome |

Notes on reading it:

- `:unknown` means Reactor returned an outcome shape ash_pplan has not
  observed; the receipt reports it as unknown rather than asserting failure
  (`lib/ash_pplan/execution_receipt.ex`, `status/1`).
- The digest addresses the *observed outcome*, not the plan or run. A succeeded
  outcome is digested over the result term (`:erlang.term_to_binary/2`
  deterministic mode — stable within one Erlang/OTP release, not a cross-version
  address). A failed outcome is digested over the failure's identity (canonical
  exception structure, stacktrace and pids dropped). A halted outcome is
  digested over the halt state plus completed step results.
- The receipt is evidence only. It is not a durable continuation checkpoint and
  grants no actuation authority (`lib/ash_pplan/execution_receipt.ex`
  moduledoc).
- Serialize it as PROV-O N-Triples with
  `AshPPlan.ExecutionReceipt.to_rdf/1`: the receipt is a `prov:Entity` typed
  `ap:ExecutionReceipt`, generated by an `ap:SemanticExecution` activity that
  `prov:used` the plan IRI.

## 4. Lower-level alternative: `AshPPlan.execute/5`

The engine API compiles and runs a plan without Ash in the loop:

```elixir
{outcome, receipt} =
  AshPPlan.execute(
    "https://w3id.org/ash-pplan#SubscriptionRenewal",
    %{
      "https://w3id.org/ash-pplan#AuthorizePayment" => MyApp.Steps.AuthorizePayment,
      "https://w3id.org/ash-pplan#RenewSubscription" => MyApp.Steps.RenewSubscription
    },
    %{order: 1}
  )
```

Signature: `execute(plan_iri, handlers, input, context \\ %{}, options \\ [])`
(`lib/ash_pplan.ex`). Returns `{reactor_outcome, receipt}` on an observed
execution — including failures, unlike the action path — and a typed refusal
`{:error, %AshPPlan.Compiler.Error{}}` with no receipt when nothing ran:
`:unknown_plan`, `:missing_handlers`, `:invalid_handlers`, `:cyclic_plan`,
`:dangling_predecessors`, `:too_many_predecessors`, `:too_many_terminal_steps`,
`:invalid_execute_arguments`, `:reserved_context_keys`.

Run identity: pass `run_id:` in `options` or `:run_id` in `context`; otherwise
one is generated (`"ash-pplan-" <> 32 hex chars`). The selected identity is
given to Reactor, placed in step context, and recorded on the receipt so all
three agree (`lib/ash_pplan.ex`, `do_execute/5`). The `:ash_pplan` context key
is reserved and refused.

Caveat (repository doctrine, `AGENTS.md` "Ash action boundary"):
`AshPPlan.execute/5` is a lower-level engine API, **not** the preferred
application authority boundary. Calling it directly skips Ash argument
validation, policy authorization, and actor/tenant setup. Prefer the
`AshPPlan.Action.Run` generic action from steps 1–2 for application actuation;
keep `execute/5` for tests, tooling, and code that already operates at the
engine layer.

## Inside a step: read predecessor results

A step implementation receives its predecessors' results through
`AshPPlan.predecessor_results/2` (`lib/ash_pplan.ex`):

```elixir
def run(arguments, context, _options) do
  %{"https://w3id.org/ash-pplan#AuthorizePayment" => authorization} =
    AshPPlan.predecessor_results(arguments, context)

  {:ok, authorization}
end
```

`p-plan:isPrecededBy` becomes a real Reactor result dependency; ash_pplan holds
no execution state of its own. Each step's context also carries
`context.ash_pplan` with `plan_iri`, `step_iri`, input/output variables and
predecessor bindings (`lib/ash_pplan/compiler.ex`, `add_step/4`).

## Related

- For workflows defined in code (not the ontology catalog), the lifecycle API
  `AshPPlan.workflow_plan/2`, `workflow_resolve/2`, `workflow_run/3`,
  `workflow_resume/2`, `workflow_observe/3` wraps planning, provider resolution
  and Reactor execution (`lib/ash_pplan/workflow/runtime.ex`). The same
  doctrine applies: it selects and validates, Reactor executes.
- Durable (ledger-backed) runs: `AshPPlan.Reactor.Durable.*` and the
  `durable:` option of the workflow runtime — see `AGENTS.md` "Durable store
  fence" before relying on a store backend.

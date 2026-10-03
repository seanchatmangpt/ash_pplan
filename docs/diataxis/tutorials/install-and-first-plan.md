# Install ash_pplan and run your first plan

A hands-on lesson: from an empty Mix project to an executed P-PLAN with a
receipt in hand. You are a student here — follow the single path top to
bottom. Why ash_pplan is shaped the way it is, and task-oriented recipes
(seeded in `docs/diataxis/how-to/`), live elsewhere.

What you will do:

1. Add the `ash_pplan` dependency.
2. Look at what the package actually gives you.
3. Implement two step handlers and run the ontology's built-in plan.
4. Read the execution receipt.
5. Enter the plan through an authorized Ash action (the app-facing boundary).
6. (If you develop the pack itself) regenerate the manufactured catalogs.

## Before you start

- Elixir `~> 1.17` (`mix.exs`, `elixir:` line).
- Familiarity with `mix` basics. No prior Ash experience is needed for steps
  1-4; step 5 assumes you have (or create) an Ash domain and resource.

## Step 1: add the dependency

In your app's `mix.exs`:

```elixir
defp deps do
  [
    {:ash_pplan, "~> 26.10"}
  ]
end
```

`ash_pplan` v26.10.2 compiles against this Ash ecosystem set (`mix.exs`,
`deps/0` in this repository): `ash ~> 3.33 and >= 3.33.11`,
`reactor ~> 1.0`, `spark ~> 2.7`, `ash_state_machine ~> 0.2.13`,
`ash_oban ~> 0.9`. If your app already uses Ash, keep your existing versions
and let the resolver reconcile; if you start fresh, the four `{:ash, ...}`,
`{:reactor, ...}`, `{:spark, ...}` entries above are the ones to add first.

Whether a published Hex package exists for this version: UNKNOWN (not
verified in this session). Two alternatives that do not depend on Hex:

```elixir
# a local checkout beside your app
{:ash_pplan, path: "../ash_pplan"}

# or pinned to an upstream commit
{:ash_pplan, github: "seanchatmangpt/ash_pplan"}
```

Then:

```bash
mix deps.get
```

## Step 2: see what you installed

`ash_pplan` is a semantic/control-plane layer, not a fourth workflow engine.
Reactor executes graphs, Ash owns actions/policies, AshStateMachine owns
persistent lifecycle legality, AshOban/Oban own background delivery.
`ash_pplan` adds what those runtimes do not compose by themselves
(`lib/ash_pplan.ex`, moduledoc). Its surface, from `lib/ash_pplan/`:

| Capability | Entry point (verified path) |
|---|---|
| Manufactured plan/projection catalogs | `lib/ash_pplan/generated/plan_catalog.ex`, `projection_catalog.ex` |
| Plan compilation to Reactor | `lib/ash_pplan/compiler.ex` (`AshPPlan.Compiler`) |
| Execution with receipt | `AshPPlan.execute/5` (`lib/ash_pplan.ex`) |
| Ash generic-action boundary | `lib/ash_pplan/action/run.ex` (`AshPPlan.Action.Run`) |
| FOND policy validation/synthesis | `lib/ash_pplan/fond.ex` |
| State machine descriptor | `lib/ash_pplan/state_machine.ex` |
| Oban descriptor | `lib/ash_pplan/oban.ex` |
| Composed control plane | `lib/ash_pplan/control_plane.ex` |
| Durable run ledger | `lib/ash_pplan/reactor/` (`AshPPlan.Reactor.Durable.*`) |

Start `iex -S mix` and ask the package what it knows. Everything below comes
from the catalogs manufactured from `ontology.ttl` — the canonical semantic
source (`lib/ash_pplan.ex`, `projections/0`, `plans/0`):

```elixir
AshPPlan.version()
#=> "26.10.2"

AshPPlan.plans()
#=> [%{iri: "https://w3id.org/ash-pplan#SubscriptionRenewal", label: "Subscription renewal", steps: [%{iri: "https://w3id.org/ash-pplan#AuthorizePayment", ...}, %{iri: "https://w3id.org/ash-pplan#RenewSubscription", ...}]}]

AshPPlan.plan("https://w3id.org/ash-pplan#SubscriptionRenewal")
#=> %{iri: "https://w3id.org/ash-pplan#SubscriptionRenewal", ...}   (plain map, or nil)
```

The subscription-renewal plan is the ontology's worked example: two steps,
`AuthorizePayment` followed by `RenewSubscription`, with P-PLAN variable flow
between them (`lib/ash_pplan/generated/plan_catalog.ex`). This shape is not
hard-coded in Elixir — it is projected from `ontology.ttl` through
`priv/ggen/ash-pplan-pack/` (gates in `priv/ggen/ash-pplan-pack/gates/*.rq`,
templates in `priv/ggen/ash-pplan-pack/templates/*.eex`). Editing the catalog
by hand is a contract violation; see Step 6.

## Step 3: your first plan execution

A plan IRI is only topology. To execute it you supply one *handler* per step:
a module implementing Reactor's `Reactor.Step` behaviour (`run/3`). The
compiler refuses a plan whose steps have no handler before anything runs
(`lib/ash_pplan/compiler.ex` line ~180: it checks
`Spark.implements_behaviour?(module, Reactor.Step)`).

Create `lib/my_app/steps.ex`:

```elixir
defmodule MyApp.Steps.AuthorizePayment do
  use Reactor.Step

  @impl true
  def run(_arguments, context, _options) do
    # context.ash_pplan.step_iri is the semantic IRI of this step
    {:ok, :authorized}
  end
end

defmodule MyApp.Steps.RenewSubscription do
  use Reactor.Step

  @impl true
  def run(arguments, context, _options) do
    predecessors = AshPPlan.predecessor_results(arguments, context)
    # %{"https://w3id.org/ash-pplan#AuthorizePayment" => :authorized}
    {:ok, {:renewed, predecessors}}
  end
end
```

`use Reactor.Step` and `run/3` are the entire handler contract; this mirrors
`test/semantic_execution_test.exs` (lines 13-38) and
`test/support/semantic_core_fixtures.ex` in the ash_pplan repository.
`AshPPlan.predecessor_results/2` turns P-PLAN precedence into the step's real
Reactor result dependencies — a step can read what its predecessors returned
(`lib/ash_pplan.ex`, `predecessor_results/2`).

Now execute:

```elixir
plan = "https://w3id.org/ash-pplan#SubscriptionRenewal"

handlers = %{
  "https://w3id.org/ash-pplan#AuthorizePayment" => MyApp.Steps.AuthorizePayment,
  "https://w3id.org/ash-pplan#RenewSubscription" => MyApp.Steps.RenewSubscription
}

{{:ok, result}, receipt} =
  AshPPlan.execute(plan, handlers, %{subscription_id: "sub_123"}, %{}, run_id: "first-run")

result
#=> {:renewed, %{"https://w3id.org/ash-pplan#AuthorizePayment" => :authorized}}

receipt.status
#=> :succeeded
```

What happened, in order (`lib/ash_pplan.ex`, `do_execute/5`):

1. `AshPPlan.Compiler.compile/2` validated the plan topology (no cycles, no
   dangling predecessors, every step has a valid `Reactor.Step` handler) and
   built a Reactor module.
2. `Reactor.run/4` executed it — Reactor remains the executor; ash_pplan
   holds no execution state of its own.
3. `AshPPlan.ExecutionReceipt.observe/5` recorded a content-addressed
   observation of the outcome.

The full signature is `execute(plan_iri, handlers, input, context \\ %{}, options \\ [])`.
`:run_id` may be passed in `options`; otherwise it is taken from context or
generated (`lib/ash_pplan.ex`, `do_execute/5`).

## Step 4: read the receipt, and learn the refusal shape

The receipt (`test/semantic_execution_test.exs`, lines 104-108, is the
executable version of these assertions) carries:

- `receipt.plan_iri` — which plan ran
- `receipt.run_id` — the identity you passed (or the generated one)
- `receipt.status` — `:succeeded` or the observed failure
- `receipt.duration_us` — wall time of the run
- `receipt.outcome_digest` — SHA-256 of the outcome (64 hex chars)

Two distinct failure shapes, worth learning now:

- **Refusal (nothing executed):** malformed topology, duplicate steps,
  dangling predecessors, cycles, missing or invalid handlers all refuse
  *before* Reactor starts, as
  `{:error, %AshPPlan.Compiler.Error{}}` — with no receipt, because there is
  nothing to observe (`lib/ash_pplan.ex`, `execute/5` moduledoc). Match on
  `AshPPlan.Compiler.Error` to tell this apart from a run that failed.
- **Observed failure:** the reactor ran and a step errored; you get
  `{{:error, reason}, receipt}` — execution happened, so there is a receipt.

## Step 5: the app-facing boundary (Ash action)

Direct `AshPPlan.execute/5` is the lower-level engine API. The preferred
boundary for a downstream application is an authorized Ash generic action
wrapping `AshPPlan.Action.Run` (`lib/ash_pplan/action/run.ex` moduledoc;
`README.md` "Preferred Ash-native execution boundary"). Ash then performs
input validation, policy authorization and actor/tenant setup *before* the
plan compiles and runs.

In your Ash resource:

```elixir
action :run_plan, :map do
  argument :plan_iri, :string, allow_nil?: false
  argument :input, :map, allow_nil?: false

  run {AshPPlan.Action.Run,
       handlers: %{
         "https://w3id.org/ash-pplan#AuthorizePayment" => MyApp.Steps.AuthorizePayment,
         "https://w3id.org/ash-pplan#RenewSubscription" => MyApp.Steps.RenewSubscription
       },
       plans: ["https://w3id.org/ash-pplan#SubscriptionRenewal"]}
end
```

Production rules baked into the implementation (`lib/ash_pplan/action/run.ex`,
moduledoc and `config/1`):

- Configure `handlers:` on the server. A caller-supplied `:handlers`
  *argument* is refused with `:handlers_argument_refused` — an argument would
  let an API caller choose which modules in the VM execute.
- `plans:` is an allowlist; an IRI outside it is refused with
  `:plan_not_allowed`.
- A halted reactor is refused with `:reactor_halted` unless
  `allow_halt?: true`.
- Refusals are `AshPPlan.Action.Run.Refusal` errors of class `:invalid`, so
  Ash surfaces them inside `Ash.Error.Invalid` and rolls back.

## Step 6: if you are developing ash_pplan itself

If you cloned this repository to change the ontology or the manufactured
catalogs, the loop is (`README.md` "Manufacture and qualification";
`bin/manufacture`):

```bash
mix deps.get          # pulls ggen_igniter, pinned by ref in mix.exs
./bin/conform         # ontology.ttl must pass ontology/shapes.ttl
./bin/conform-falsify # ... and the profile must still refuse counterexamples
./bin/manufacture     # ggen_igniter re-renders lib/ash_pplan/generated/
git diff --exit-code -- lib/ash_pplan/generated   # generated must be reproducible
mix check             # format check + test suite
```

`bin/manufacture` runs `mix ggen_igniter.sync` twice — once per template in
`priv/ggen/ash-pplan-pack/templates/` — then formats the outputs and
manufactures the workflow pack. The generated files are consequences: to
change a plan's steps, edit `ontology.ttl` (never `lib/ash_pplan/generated/`,
never the catalog by hand) and re-run manufacture.

## What you learned

- `ash_pplan` adds a semantic control plane over Ash/Reactor/
  AshStateMachine/AshOban; it executes nothing itself.
- Plans are projected from `ontology.ttl`; the catalogs under
  `lib/ash_pplan/generated/` are the manufactured read surface.
- A plan executes when you map each step IRI to a `Reactor.Step` handler and
  call `AshPPlan.execute/5`; you get the result and an `ExecutionReceipt`.
- Refusals (compile-time) and failures (observed) are distinct shapes.
- Applications should enter through an Ash generic action over
  `AshPPlan.Action.Run`, with server-side handlers and a plan allowlist.

Standing note: the code paths cited here were read and verified against
source in this session; the runnable versions of every snippet live in the
repository's test suite (`test/semantic_execution_test.exs`,
`test/action_run_test.exs`). Whether the snippets above run on *your* machine
is something you observe by running them — that observation is yours, not
this document's to claim.

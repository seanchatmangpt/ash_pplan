defmodule AshPPlan.Test.Steps.Emit do
  @moduledoc """
  Reactor step that returns its configured value (default: its step IRI).
  """

  use Reactor.Step

  @impl true
  def run(_arguments, context, options) do
    {:ok, Keyword.get(options, :value, context.ash_pplan.step_iri)}
  end
end

defmodule AshPPlan.Test.Steps.HaltUntilResumed do
  @moduledoc """
  Reactor step that halts the run unless the run context carries
  `:resumed_by`. Reactor records the halt value as the step's result, so the
  value is what a successor observes after resumption.
  """

  use Reactor.Step

  @impl true
  def run(_arguments, context, _options) do
    if Map.has_key?(context, :resumed_by) do
      {:ok, :authorized_on_resume}
    else
      {:halt, :awaiting_authorization}
    end
  end
end

defmodule AshPPlan.Test.Steps.Observe do
  @moduledoc """
  Reactor step that reports what the run actually handed it: predecessor
  results, input, identity and the Ash scope (actor/tenant/authorize?), and
  whether it executes inside a data-layer transaction of the configured
  resource.
  """

  use Reactor.Step

  @impl true
  def run(arguments, context, options) do
    in_transaction? =
      case Keyword.get(options, :transaction_resource) do
        nil -> nil
        resource -> Ash.DataLayer.in_transaction?(resource)
      end

    {:ok,
     %{
       predecessors: AshPPlan.predecessor_results(arguments, context),
       input: Map.get(arguments, :input),
       run_id: Map.get(context, :run_id),
       resumed_by: Map.get(context, :resumed_by),
       actor: Map.get(context, :actor),
       tenant: Map.get(context, :tenant),
       authorize?: Map.get(context, :authorize?),
       in_transaction?: in_transaction?,
       pid: self()
     }}
  end
end

defmodule AshPPlan.Test.Steps.Fail do
  @moduledoc "Reactor step that always fails."

  use Reactor.Step

  @impl true
  def run(_arguments, _context, _options), do: {:error, RuntimeError.exception("step failed")}
end

defmodule AshPPlan.Test.Steps.Closure do
  @moduledoc "Reactor step that returns a runtime-only closure as its result."

  use Reactor.Step

  @impl true
  def run(_arguments, _context, _options) do
    pid = self()
    {:halt, fn -> pid end}
  end
end

defmodule AshPPlan.Test.PlanRunDomain do
  @moduledoc false

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshPPlan.Test.PlanRunResource
    resource AshPPlan.Test.TransactionalPlanRunResource
  end
end

defmodule AshPPlan.Test.PlanRunResource do
  @moduledoc """
  ETS-backed resource whose generic actions execute P-PLANs through
  `AshPPlan.Action.Run`, exercising the real Ash action boundary.
  """

  use Ash.Resource,
    domain: AshPPlan.Test.PlanRunDomain,
    data_layer: Ash.DataLayer.Ets

  @plan "https://w3id.org/ash-pplan#SubscriptionRenewal"
  @authorize "https://w3id.org/ash-pplan#AuthorizePayment"
  @renew "https://w3id.org/ash-pplan#RenewSubscription"

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
  end

  actions do
    defaults [:read]

    action :run_dynamic, :map do
      argument :plan_iri, :string, allow_nil?: false
      argument :handlers, :term
      argument :input, :term
      run AshPPlan.Action.Run
    end

    action :run_configured, :map do
      argument :plan_iri, :string, allow_nil?: false
      argument :handlers, :term
      argument :input, :term

      run {AshPPlan.Action.Run,
           plans: [@plan],
           handlers: %{
             @authorize => AshPPlan.Test.Steps.Emit,
             @renew => AshPPlan.Test.Steps.Observe
           }}
    end

    action :run_halting, :map do
      argument :plan_iri, :string, allow_nil?: false
      argument :input, :term

      run {AshPPlan.Action.Run,
           plans: [@plan],
           handlers: %{
             @authorize => AshPPlan.Test.Steps.HaltUntilResumed,
             @renew => AshPPlan.Test.Steps.Observe
           }}
    end

    action :run_halting_admitted, :map do
      argument :plan_iri, :string, allow_nil?: false
      argument :input, :term

      run {AshPPlan.Action.Run,
           allow_halt?: true,
           plans: [@plan],
           handlers: %{
             @authorize => AshPPlan.Test.Steps.HaltUntilResumed,
             @renew => AshPPlan.Test.Steps.Observe
           }}
    end
  end
end

defmodule AshPPlan.Test.TransactionalPlanRunResource do
  @moduledoc """
  Mnesia-backed resource (a data layer that supports transactions) whose
  transactional generic action executes a P-PLAN through
  `AshPPlan.Action.Run`.
  """

  use Ash.Resource,
    domain: AshPPlan.Test.PlanRunDomain,
    data_layer: Ash.DataLayer.Mnesia

  @plan "https://w3id.org/ash-pplan#SubscriptionRenewal"
  @authorize "https://w3id.org/ash-pplan#AuthorizePayment"
  @renew "https://w3id.org/ash-pplan#RenewSubscription"

  attributes do
    uuid_primary_key :id
  end

  actions do
    defaults [:read]

    action :run_in_transaction, :map do
      transaction? true
      argument :plan_iri, :string, allow_nil?: false
      argument :input, :term

      run {AshPPlan.Action.Run,
           plans: [@plan],
           handlers: %{
             @authorize => AshPPlan.Test.Steps.Emit,
             @renew =>
               {AshPPlan.Test.Steps.Observe,
                transaction_resource: AshPPlan.Test.TransactionalPlanRunResource}
           }}
    end
  end
end

defmodule AshPPlan.Test.UncheckedETFCodec do
  @moduledoc """
  Adversarial codec: claims the default ETF codec identity but encodes any
  term without a portability check. Used to prove that decode, not only
  encode, refuses runtime-only terms.
  """

  @behaviour AshPPlan.Continuation.Codec

  @impl true
  def id, do: AshPPlan.Continuation.ETFCodec.id()

  @impl true
  def version, do: AshPPlan.Continuation.ETFCodec.version()

  @impl true
  def encode(term), do: {:ok, :erlang.term_to_binary(term)}

  @impl true
  def decode(payload), do: {:ok, :erlang.binary_to_term(payload)}
end

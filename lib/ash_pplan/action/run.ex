defmodule AshPPlan.Action.Run do
  @moduledoc """
  Ash generic-action implementation for executing a dynamically compiled P-PLAN.

  This is the preferred downstream DO boundary when the plan is dynamic and
  therefore cannot be supplied directly as a Reactor module in the Ash action
  DSL. Ash performs action validation, policy authorization and actor/tenant
  setup before this implementation runs; this module then delegates the actual
  workflow execution to `AshPPlan.execute/5` and Reactor.

  ## Options (`run {AshPPlan.Action.Run, opts}`)

    * `:handlers` - a map of step IRI to `Reactor.Step` implementation, fixed
      on the server. **This is the production path.** When configured, a
      caller-supplied `:handlers` argument is refused with
      `:handlers_argument_refused`, because an action argument would let an
      API caller choose which step modules loaded in the VM are executed.
    * `:plans` - an allowlist of plan IRIs. A `:plan_iri` argument outside it
      is refused with `:plan_not_allowed`.
    * `:allow_halt?` - when `true`, a halted Reactor is returned as
      `{:ok, %{outcome: {:halted, reactor}, receipt: receipt}}` so the
      application can capture it. Defaults to `false`: a halt is refused with
      `:reactor_halted`, which also rolls back an enclosing transaction.
    * `:reactor_options` - Reactor run options.

  Expected generic-action arguments are `:plan_iri` and `:input`, plus
  `:handlers` only when no server-side `:handlers` option is configured
  (retained for backward compatibility; prefer the option).

  A failed Reactor outcome is returned as `{:error, errors}`, unwrapping a
  `Reactor.Error` class the way Ash does for Reactor-backed actions, so Ash
  classifies step errors (e.g. a nested `Ash.Error.Forbidden`) and rolls back.
  Receipts are returned only for admitted outcomes; call `AshPPlan.execute/5`
  directly to observe a receipt for a failure.

  When the action runs inside a data-layer transaction, Reactor is forced to
  run synchronously (`async?: false`), as Ash does for Reactor-backed actions,
  so every step executes inside that transaction.
  """

  use Ash.Resource.Actions.Implementation

  defmodule Refusal do
    @moduledoc """
    Typed refusal returned by `AshPPlan.Action.Run`.

    It is a Splode error of class `:invalid`, so Ash surfaces it inside an
    `Ash.Error.Invalid` rather than flattening it into an unknown error.
    """

    use Splode.Error, fields: [:reason, details: %{}], class: :invalid

    @impl true
    def message(%{reason: reason, details: details}) do
      "ash_pplan action refused #{reason}: #{inspect(details)}"
    end
  end

  @impl true
  def run(action_input, opts, context) when is_map(action_input) and is_list(opts) do
    with {:ok, config} <- config(opts),
         {:ok, plan_iri} <- fetch_argument(action_input.arguments, :plan_iri),
         :ok <- validate_plan_iri(plan_iri, config.plans),
         {:ok, handlers} <- handlers(action_input.arguments, config.handlers),
         {:ok, input} <- fetch_argument(action_input.arguments, :input) do
      reactor_context = context |> Ash.Scope.to_opts() |> Map.new()
      reactor_options = transaction_options(action_input, config.reactor_options)

      plan_iri
      |> AshPPlan.execute(handlers, input, reactor_context, reactor_options)
      |> admit(config.allow_halt?)
    end
  end

  # Typed-refusal law: a direct invocation with a malformed input/opts shape
  # is a typed refusal, never a FunctionClauseError.
  def run(_action_input, _opts, _context) do
    refuse(:invalid_action_invocation, %{})
  end

  defp admit({{:ok, _result} = outcome, receipt}, _allow_halt?),
    do: {:ok, %{outcome: outcome, receipt: receipt}}

  defp admit({{:ok, _result, _reactor} = outcome, receipt}, _allow_halt?),
    do: {:ok, %{outcome: outcome, receipt: receipt}}

  defp admit({{:halted, _reactor} = outcome, receipt}, true),
    do: {:ok, %{outcome: outcome, receipt: receipt}}

  defp admit({{:halted, _reactor}, receipt}, _allow_halt?),
    do: refuse(:reactor_halted, %{run_id: receipt.run_id, receipt: receipt})

  defp admit({{:error, %{splode: Reactor.Error, errors: errors}}, _receipt}, _allow_halt?),
    do: {:error, errors}

  defp admit({{:error, error}, _receipt}, _allow_halt?), do: {:error, error}

  defp admit({:error, error}, _allow_halt?), do: {:error, error}

  defp admit({outcome, receipt}, _allow_halt?),
    do: refuse(:unrecognised_outcome, %{outcome: outcome, receipt: receipt})

  # Typed-refusal law: a direct invocation with a malformed input/opts shape
  # is a typed refusal, never a FunctionClauseError.
  def run(_action_input, _opts, _context) do
    refuse(:invalid_action_invocation, %{})
  end

  # Typed-refusal law: a direct invocation with a malformed input/opts shape
  # is a typed refusal, never a FunctionClauseError.
  def run(_action_input, _opts, _context) do
    refuse(:invalid_action_invocation, %{})
  end

  defp config(opts) do
    handlers = Keyword.get(opts, :handlers)
    plans = Keyword.get(opts, :plans)
    allow_halt? = Keyword.get(opts, :allow_halt?, false)
    reactor_options = Keyword.get(opts, :reactor_options, [])

    cond do
      not (is_nil(handlers) or is_map(handlers)) ->
        refuse(:invalid_action_options, %{option: :handlers})

      not (is_nil(plans) or (is_list(plans) and Enum.all?(plans, &is_binary/1))) ->
        refuse(:invalid_action_options, %{option: :plans})

      not is_boolean(allow_halt?) ->
        refuse(:invalid_action_options, %{option: :allow_halt?})

      not (is_list(reactor_options) and Keyword.keyword?(reactor_options)) ->
        refuse(:invalid_action_options, %{option: :reactor_options})

      true ->
        {:ok,
         %{
           handlers: handlers,
           plans: plans,
           allow_halt?: allow_halt?,
           reactor_options: reactor_options
         }}
    end
  end

  defp validate_plan_iri(plan_iri, _plans) when not is_binary(plan_iri),
    do: refuse(:invalid_action_arguments, %{argument: :plan_iri})

  defp validate_plan_iri(_plan_iri, nil), do: :ok

  defp validate_plan_iri(plan_iri, plans) do
    if plan_iri in plans do
      :ok
    else
      refuse(:plan_not_allowed, %{plan_iri: plan_iri})
    end
  end

  defp handlers(arguments, nil) do
    case fetch_argument(arguments, :handlers) do
      {:ok, handlers} when is_map(handlers) -> {:ok, handlers}
      {:ok, _handlers} -> refuse(:invalid_action_arguments, %{argument: :handlers})
      error -> error
    end
  end

  defp handlers(arguments, configured) do
    if is_nil(Map.get(arguments, :handlers)) do
      {:ok, configured}
    else
      refuse(:handlers_argument_refused, %{})
    end
  end

  defp transaction_options(action_input, reactor_options) do
    resources = [action_input.resource | List.wrap(action_input.action.touches_resources)]

    if Enum.any?(resources, &Ash.DataLayer.in_transaction?/1) do
      Keyword.put(reactor_options, :async?, false)
    else
      reactor_options
    end
  end

  defp fetch_argument(arguments, name) when is_map(arguments) do
    case Map.fetch(arguments, name) do
      {:ok, value} -> {:ok, value}
      :error -> refuse(:missing_action_argument, %{argument: name})
    end
  end

  defp fetch_argument(_arguments, name) do
    refuse(:invalid_action_arguments, %{argument: name})
  end

  defp refuse(reason, details), do: {:error, Refusal.exception(reason: reason, details: details)}
end

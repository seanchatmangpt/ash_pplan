defmodule AshPPlan.Action.Run do
  @moduledoc """
  Ash generic-action implementation for executing a dynamically compiled P-PLAN.

  This is the preferred downstream DO boundary when the plan is dynamic and
  therefore cannot be supplied directly as a Reactor module in the Ash action
  DSL. Ash performs action validation, policy authorization and actor/tenant
  setup before this implementation runs; this module then delegates the actual
  workflow execution to `AshPPlan.execute/5` and Reactor.

  Expected generic-action arguments are `:plan_iri`, `:handlers` and `:input`.
  Reactor runtime options may be configured with `reactor_options:` in the
  action's `run` options.
  """

  use Ash.Resource.Actions.Implementation

  @impl true
  def run(action_input, opts, context) do
    with {:ok, plan_iri} <- fetch_argument(action_input.arguments, :plan_iri),
         {:ok, handlers} <- fetch_argument(action_input.arguments, :handlers),
         {:ok, input} <- fetch_argument(action_input.arguments, :input),
         :ok <- validate_arguments(plan_iri, handlers) do
      reactor_context = context |> Ash.Scope.to_opts() |> Map.new()
      reactor_options = Keyword.get(opts, :reactor_options, [])

      case AshPPlan.execute(plan_iri, handlers, input, reactor_context, reactor_options) do
        {:error, error} -> {:error, error}
        {outcome, receipt} -> {:ok, %{outcome: outcome, receipt: receipt}}
      end
    end
  end

  defp fetch_argument(arguments, name) do
    case Map.fetch(arguments, name) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        {:error, ArgumentError.exception("missing ash_pplan action argument #{inspect(name)}")}
    end
  end

  defp validate_arguments(plan_iri, handlers) when is_binary(plan_iri) and is_map(handlers),
    do: :ok

  defp validate_arguments(plan_iri, handlers) do
    {:error,
     ArgumentError.exception(
       "expected :plan_iri to be a string and :handlers to be a map, got: " <>
         "#{inspect(plan_iri)} and #{inspect(handlers)}"
     )}
  end
end

defmodule AshPPlan.Reactor.Middleware.Evidence do
  @moduledoc """
  Reactor middleware that binds run evidence to the workflow subject through
  `AshPPlan.Workflow.Evidence` and emits the workflow telemetry event on
  completion, error and halt. The result a run returns is never altered, and
  evidence grants no authority.
  """

  use Reactor.Middleware

  alias AshPPlan.Workflow.Evidence

  @key AshPPlan.Reactor.context_key()

  @impl true
  def complete(result, context) do
    emit(context, {:ok, result})
    {:ok, result}
  end

  @impl true
  def error(errors, context) do
    emit(context, {:error, errors})
    :ok
  end

  @impl true
  def halt(context) do
    emit(context, {:halted, %{state: :halted, intermediate_results: %{}}})
    {:ok, context}
  end

  defp emit(%{@key => %{subject: subject, workflow: workflow}} = context, outcome) do
    run_id = to_string(Map.get(context, :run_id, "unknown"))

    Evidence.bind(%{id: subject, workflow: workflow},
      run_id: run_id,
      outcome: outcome,
      emit: true
    )

    :ok
  end

  defp emit(_context, _outcome), do: :ok
end

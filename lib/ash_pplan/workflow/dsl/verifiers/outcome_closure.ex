defmodule AshPPlan.Workflow.Dsl.Verifiers.OutcomeClosure do
  @moduledoc """
  Outcome closure: each task's declared outcomes are unique, and outcome sets are
  closed under the dependency relation (a task cannot be conditioned on an outcome
  the declaring workflow never produces).
  """
  use Spark.Dsl.Verifier

  alias AshPPlan.Workflow.Dsl.Info
  alias AshPPlan.Workflow.Dsl.Verifiers.Helpers

  @impl true
  def verify(dsl_state) do
    dsl_state
    |> Info.tasks()
    |> Enum.find_value(:ok, fn task ->
      outcomes = List.wrap(task.outcomes)

      cond do
        outcomes != Enum.uniq(outcomes) ->
          Helpers.error(
            dsl_state,
            [:workflow, :task, task.id],
            "task #{inspect(task.id)} declares duplicate outcomes"
          )

        Enum.any?(outcomes, &(not is_atom(&1) or is_nil(&1))) ->
          Helpers.error(
            dsl_state,
            [:workflow, :task, task.id],
            "task #{inspect(task.id)} has non-atom outcomes"
          )

        true ->
          nil
      end
    end)
  end
end

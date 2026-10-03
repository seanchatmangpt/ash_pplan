defmodule AshPPlan.Workflow.Dsl.Verifiers.OutcomeClosure do
  @moduledoc """
  Outcome well-formedness per task: declared outcomes are unique atoms. (The DSL
  has no outcome-reference construct — no task field names another task's
  outcomes — so there is no cross-task outcome closure to check here. The only
  real closure property, `terminal_outcomes ⊆ outcomes`, is a runtime-struct
  invariant enforced by `AshPPlan.Workflow.Model.validate/1`, not a DSL-level
  one.)
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

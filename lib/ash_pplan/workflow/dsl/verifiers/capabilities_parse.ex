defmodule AshPPlan.Workflow.Dsl.Verifiers.CapabilitiesParse do
  @moduledoc "Every task capability must parse via `AshPPlan.Capability.parse/1`; authority must not exceed :construct."
  use Spark.Dsl.Verifier

  alias AshPPlan.Capability
  alias AshPPlan.Workflow.Dsl.Info
  alias AshPPlan.Workflow.Dsl.Verifiers.Helpers

  @authorities [:none, :observe, :select, :construct]

  @impl true
  def verify(dsl_state) do
    dsl_state
    |> Info.tasks()
    |> Enum.find_value(:ok, fn task ->
      cond do
        match?({:error, _}, Capability.parse(task.capability)) ->
          Helpers.error(
            dsl_state,
            [:workflow, :task, task.id],
            "task #{inspect(task.id)} has unparseable capability #{inspect(task.capability)} (expected Family.Name)"
          )

        task.authority not in @authorities ->
          Helpers.error(
            dsl_state,
            [:workflow, :task, task.id],
            "task #{inspect(task.id)} authority #{inspect(task.authority)} exceeds ceiling :construct"
          )

        true ->
          nil
      end
    end)
  end
end

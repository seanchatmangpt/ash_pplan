defmodule AshPPlan.Workflow.Dsl.Verifiers.UniqueIds do
  @moduledoc "Task ids and method ids must be unique; method references must resolve."
  use Spark.Dsl.Verifier

  alias AshPPlan.Workflow.Dsl.Info
  alias AshPPlan.Workflow.Dsl.Verifiers.Helpers

  @impl true
  def verify(dsl_state) do
    tasks = Enum.map(Info.tasks(dsl_state), & &1.id)
    methods = Enum.map(Info.methods(dsl_state), & &1.id)

    with :ok <- unique(dsl_state, :task, tasks),
         :ok <- unique(dsl_state, :method, methods) do
      method_refs(dsl_state, MapSet.new(tasks))
    end
  end

  defp unique(dsl_state, kind, ids) do
    case ids -- Enum.uniq(ids) do
      [] ->
        :ok

      dup ->
        Helpers.error(
          dsl_state,
          [:workflow, kind],
          "duplicate #{kind} ids: #{inspect(Enum.uniq(dup))}"
        )
    end
  end

  defp method_refs(dsl_state, task_ids) do
    unknown =
      dsl_state
      |> Info.methods()
      |> Enum.flat_map(fn m ->
        m.subtasks |> List.wrap() |> Enum.reject(&MapSet.member?(task_ids, &1))
      end)

    case unknown do
      [] ->
        :ok

      _ ->
        Helpers.error(
          dsl_state,
          [:workflow, :method],
          "methods reference undeclared tasks: #{inspect(Enum.uniq(unknown))}"
        )
    end
  end
end

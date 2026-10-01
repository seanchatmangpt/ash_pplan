defmodule AshPPlan.Workflow.Dsl.Verifiers.AcyclicDependencies do
  @moduledoc "`after` references must resolve and the dependency graph must be acyclic."
  use Spark.Dsl.Verifier

  alias AshPPlan.Workflow.Dsl.Info
  alias AshPPlan.Workflow.Dsl.Verifiers.Helpers

  @impl true
  def verify(dsl_state) do
    graph = Map.new(Info.tasks(dsl_state), &{&1.id, List.wrap(&1.after)})

    case graph |> Map.values() |> List.flatten() |> Enum.reject(&Map.has_key?(graph, &1)) do
      [] ->
        check_cycles(dsl_state, graph)

      missing ->
        Helpers.error(
          dsl_state,
          [:workflow, :task],
          "unknown dependencies: #{inspect(Enum.uniq(missing))}"
        )
    end
  end

  defp check_cycles(dsl_state, graph) do
    case cyclic_nodes(graph) do
      [] ->
        :ok

      nodes ->
        Helpers.error(
          dsl_state,
          [:workflow, :task],
          "dependency cycle among tasks: #{inspect(nodes)}"
        )
    end
  end

  # Kahn elimination: whatever cannot be removed lies on or behind a cycle.
  defp cyclic_nodes(graph) do
    case Enum.filter(graph, fn {_id, deps} -> deps == [] end) do
      [] ->
        graph |> Map.keys() |> Enum.sort()

      ready ->
        done = Enum.map(ready, &elem(&1, 0))
        rest = graph |> Map.drop(done) |> Map.new(fn {id, deps} -> {id, deps -- done} end)
        if rest == %{}, do: [], else: cyclic_nodes(rest)
    end
  end
end

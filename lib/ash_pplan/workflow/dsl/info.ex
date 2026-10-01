defmodule AshPPlan.Workflow.Dsl.Info do
  @moduledoc """
  Introspection and lenient model construction for `AshPPlan.Workflow` DSL modules.

  Construction here never validates; verifiers (and `AshPPlan.Workflow.Model.new/1`)
  own validation, so an invalid DSL still produces a model that the verifiers can
  reject with a precise error.
  """

  alias AshPPlan.Workflow.Model
  alias AshPPlan.Workflow.Dsl.Method, as: MethodEntity
  alias AshPPlan.Workflow.Dsl.Task, as: TaskEntity

  @doc "Raw task entities declared in a DSL module or dsl_state."
  def tasks(dsl), do: entities(dsl, TaskEntity)
  @doc "Raw method entities declared in a DSL module or dsl_state."
  def methods(dsl), do: entities(dsl, MethodEntity)

  @doc "Goal option."
  def goal(dsl), do: Spark.Dsl.Extension.get_opt(dsl, [:workflow], :goal, nil)

  @doc "Workflow name (string); defaults to the underscored last module segment."
  def name(dsl, module \\ nil) do
    case Spark.Dsl.Extension.get_opt(dsl, [:workflow], :name, nil) do
      nil -> default_name(module || Spark.Dsl.Extension.get_persisted(dsl, :module))
      name -> to_string(name)
    end
  end

  @doc "Version option."
  def version(dsl), do: Spark.Dsl.Extension.get_opt(dsl, [:workflow], :version, 1)

  @doc "Build a `Model` struct without validating it."
  @spec build(term(), module() | nil) :: Model.t()
  def build(dsl, module \\ nil) do
    tasks = dsl |> tasks() |> Enum.map(&to_task/1) |> Enum.sort_by(& &1.id)

    %Model{
      name: name(dsl, module),
      version: version(dsl),
      goal: goal(dsl),
      tasks: tasks,
      methods: dsl |> methods() |> Enum.map(&to_method/1) |> Enum.sort_by(& &1.id),
      outcome_topology: Map.new(tasks, &{&1.id, &1.outcomes})
    }
  end

  defp entities(dsl, struct) do
    dsl
    |> Spark.Dsl.Extension.get_entities([:workflow])
    |> Enum.filter(&match?(%{__struct__: ^struct}, &1))
  end

  defp to_task(%TaskEntity{} = t) do
    Model.task(%{
      id: t.id,
      capability: capability_string(t.capability),
      depends_on: List.wrap(t.after),
      outcomes: List.wrap(t.outcomes),
      properties: List.wrap(t.properties),
      evidence: List.wrap(t.evidence),
      authority: t.authority
    })
  end

  defp to_method(%MethodEntity{} = m) do
    Model.method(%{
      id: m.id,
      task: m.task,
      subtasks: List.wrap(m.subtasks),
      precondition: m.precondition
    })
  end

  defp capability_string(nil), do: nil
  defp capability_string(cap) when is_atom(cap), do: Atom.to_string(cap)
  defp capability_string(cap), do: cap

  defp default_name(nil), do: "workflow"

  defp default_name(module) do
    module |> Module.split() |> List.last() |> Macro.underscore()
  end
end

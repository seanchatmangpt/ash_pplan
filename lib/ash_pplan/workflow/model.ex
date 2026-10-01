defmodule AshPPlan.Workflow.Model do
  @moduledoc """
  Canonical, normalized semantic workflow model.

  P-PLAN, HDDL, FOND and Reactor views are projections of this struct; none is
  the source. All ordering is normalized so equal semantics yield equal identity.
  """

  alias AshPPlan.Workflow.{Method, Task}

  @enforce_keys [:name]
  defstruct name: nil, version: 1, goal: nil, tasks: [], methods: [], outcome_topology: %{}

  @type t :: %__MODULE__{}

  @doc "Build a normalized model from a keyword/map description."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, map()}
  def new(attrs) do
    attrs = Map.new(attrs)

    with {:ok, name} <- fetch_name(attrs),
         tasks <- attrs |> Map.get(:tasks, []) |> Enum.map(&task/1) |> Enum.sort_by(& &1.id),
         :ok <- check_unique(tasks),
         :ok <- check_dependencies(tasks) do
      {:ok,
       %__MODULE__{
         name: name,
         version: Map.get(attrs, :version, 1),
         goal: Map.get(attrs, :goal),
         tasks: tasks,
         methods: attrs |> Map.get(:methods, []) |> Enum.map(&method/1) |> Enum.sort_by(& &1.id),
         outcome_topology: Map.new(tasks, &{&1.id, &1.outcomes})
       }}
    end
  end

  @spec task(Task.t() | keyword() | map()) :: Task.t()
  def task(%Task{} = t), do: normalize(t)

  def task(attrs) do
    attrs = Map.new(attrs)
    attrs = Map.put_new(attrs, :depends_on, Map.get(attrs, :after, []))
    normalize(struct!(Task, Map.drop(attrs, [:after])))
  end

  @spec method(Method.t() | keyword() | map()) :: Method.t()
  def method(%Method{} = m), do: m
  def method(attrs), do: struct!(Method, Map.new(attrs))

  @doc "Canonical term used for identity (deterministic, authority-free)."
  @spec canonical(t()) :: map()
  def canonical(%__MODULE__{} = m) do
    %{
      name: m.name,
      version: m.version,
      goal: m.goal,
      tasks: Enum.map(m.tasks, &Map.from_struct/1),
      methods: Enum.map(m.methods, &Map.from_struct/1)
    }
  end

  defp normalize(%Task{} = t) do
    %{
      t
      | depends_on: t.depends_on |> List.wrap() |> Enum.sort(),
        outcomes: t.outcomes |> List.wrap() |> Enum.sort(),
        properties: t.properties |> List.wrap() |> Enum.sort(),
        evidence: t.evidence |> List.wrap() |> Enum.sort()
    }
  end

  defp fetch_name(%{name: name}) when is_atom(name) or is_binary(name), do: {:ok, to_string(name)}
  defp fetch_name(_), do: {:error, %{reason: :missing_workflow_name}}

  defp check_unique(tasks) do
    ids = Enum.map(tasks, & &1.id)

    case ids -- Enum.uniq(ids) do
      [] -> :ok
      dup -> {:error, %{reason: :duplicate_tasks, tasks: Enum.uniq(dup)}}
    end
  end

  defp check_dependencies(tasks) do
    ids = MapSet.new(tasks, & &1.id)

    case tasks |> Enum.flat_map(& &1.depends_on) |> Enum.reject(&MapSet.member?(ids, &1)) do
      [] -> :ok
      missing -> {:error, %{reason: :unknown_dependencies, tasks: Enum.uniq(missing)}}
    end
  end
end

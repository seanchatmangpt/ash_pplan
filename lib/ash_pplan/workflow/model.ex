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
         :ok <- check_dependencies(tasks),
         {:ok, _order} <- topological_order(tasks) do
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

  @authorities [:none, :observe, :select, :plan, :construct]

  @doc "Authority ceilings a task may declare. `:do` is never among them."
  @spec authorities() :: [atom()]
  def authorities, do: @authorities

  @doc """
  Full structural validation: unique ids, resolvable dependencies, acyclicity,
  parseable capabilities, authority at or below the `:construct` ceiling, and
  methods that only refer to declared tasks. Returns the first violation.
  """
  @spec validate(t()) :: :ok | {:error, map()}
  def validate(%__MODULE__{} = m) do
    with :ok <- check_unique(m.tasks),
         :ok <- check_dependencies(m.tasks),
         {:ok, _} <- topological_order(m.tasks),
         :ok <- check_capabilities(m.tasks),
         :ok <- check_authority(m.tasks) do
      check_methods(m)
    end
  end

  def validate(other), do: {:error, %{reason: :not_a_model, value: other}}

  @doc "Dependency-respecting task id order (ties broken by id) or the cyclic remainder."
  @spec topological_order([Task.t()] | t()) :: {:ok, [atom() | String.t()]} | {:error, map()}
  def topological_order(%__MODULE__{tasks: tasks}), do: topological_order(tasks)

  def topological_order(tasks) when is_list(tasks) do
    deps = Map.new(tasks, &{&1.id, MapSet.new(&1.depends_on)})
    kahn(deps, [])
  end

  defp kahn(deps, acc) when map_size(deps) == 0, do: {:ok, Enum.reverse(acc)}

  defp kahn(deps, acc) do
    ready = for {id, d} <- deps, MapSet.size(d) == 0, do: id

    case Enum.sort(ready) do
      [] ->
        {:error, %{reason: :cyclic_dependencies, tasks: deps |> Map.keys() |> Enum.sort()}}

      [next | _] ->
        rest = deps |> Map.delete(next) |> Map.new(fn {id, d} -> {id, MapSet.delete(d, next)} end)
        kahn(rest, [next | acc])
    end
  end

  defp check_capabilities(tasks) do
    case Enum.reject(tasks, &AshPPlan.Capability.valid?(&1.capability)) do
      [] -> :ok
      bad -> {:error, %{reason: :invalid_capability, tasks: Enum.map(bad, & &1.id)}}
    end
  end

  defp check_authority(tasks) do
    case Enum.reject(tasks, &(&1.authority in @authorities)) do
      [] ->
        :ok

      bad ->
        {:error,
         %{
           reason: :authority_above_ceiling,
           ceiling: :construct,
           tasks: Enum.map(bad, &{&1.id, &1.authority})
         }}
    end
  end

  defp check_methods(%__MODULE__{methods: methods, tasks: tasks}) do
    ids = MapSet.new(tasks, & &1.id)

    case methods |> Enum.flat_map(& &1.subtasks) |> Enum.reject(&MapSet.member?(ids, &1)) do
      [] -> :ok
      missing -> {:error, %{reason: :unknown_method_subtasks, tasks: Enum.uniq(missing)}}
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
      | capability: capability_id(t.capability),
        depends_on: set(t.depends_on),
        outcomes: set(t.outcomes),
        properties: set(t.properties),
        evidence: set(t.evidence)
    }
  end

  defp set(value), do: value |> List.wrap() |> Enum.uniq() |> Enum.sort()

  defp capability_id(nil), do: nil

  defp capability_id(value) do
    case AshPPlan.Capability.normalize(value) do
      {:ok, id} -> id
      {:error, _} -> value
    end
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

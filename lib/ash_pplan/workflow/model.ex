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
  def new(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = Map.new(attrs)

    with {:ok, name} <- fetch_name(attrs),
         {:ok, tasks} <- build_tasks(Map.get(attrs, :tasks, [])),
         tasks = Enum.sort_by(tasks, & &1.id),
         :ok <- check_unique(tasks),
         :ok <- check_dependencies(tasks),
         :ok <- check_terminal(tasks),
         {:ok, _order} <- topological_order(tasks),
         {:ok, methods} <- build_methods(Map.get(attrs, :methods, [])) do
      {:ok,
       %__MODULE__{
         name: name,
         version: Map.get(attrs, :version, 1),
         goal: Map.get(attrs, :goal),
         tasks: tasks,
         methods: Enum.sort_by(methods, & &1.id),
         outcome_topology: Map.new(tasks, &{&1.id, &1.outcomes})
       }}
    end
  end

  # Typed-refusal law: garbage attrs are a typed rejection, never a
  # BadMapError / KeyError / struct! crash.
  def new(other), do: {:error, %{reason: :invalid_workflow_attrs, value: other}}

  defp build_tasks(tasks) when is_list(tasks) do
    Enum.reduce_while(tasks, {:ok, []}, fn entry, {:ok, acc} ->
      case build_task(entry) do
        {:ok, t} -> {:cont, {:ok, [t | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp build_tasks(other), do: {:error, %{reason: :invalid_tasks, value: other}}

  defp build_task(%Task{} = t), do: {:ok, normalize(t)}

  defp build_task(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = Map.new(attrs)

    id = Map.get(attrs, :id)

    cond do
      is_nil(id) ->
        {:error, %{reason: :missing_task_id, task: nil}}

      not (is_atom(id) or is_binary(id)) ->
        {:error, %{reason: :missing_task_id, task: id}}

      Map.has_key?(attrs, :after) and Map.has_key?(attrs, :depends_on) ->
        {:error, %{reason: :ambiguous_dependency_key, task: id}}

      true ->
        unknown = Map.keys(attrs) -- (Task.__struct__() |> Map.keys())
        fields = Map.drop(attrs, [:after])

        case unknown -- [:after] do
          [] ->
            {:ok, normalize(struct!(Task, Map.put_new(fields, :depends_on, attrs[:after] || [])))}

          extra ->
            {:error, %{reason: :unknown_task_fields, task: id, fields: Enum.sort(extra)}}
        end
    end
  end

  defp build_task(other), do: {:error, %{reason: :invalid_task, value: other}}

  defp build_methods(methods) when is_list(methods) do
    Enum.reduce_while(methods, {:ok, []}, fn entry, {:ok, acc} ->
      case build_method(entry) do
        {:ok, m} -> {:cont, {:ok, [m | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp build_methods(other), do: {:error, %{reason: :invalid_methods, value: other}}

  defp build_method(%Method{} = m), do: {:ok, m}

  defp build_method(attrs) when is_list(attrs) or is_map(attrs) do
    id = Map.get(Map.new(attrs), :id)

    if not is_nil(id) and (is_atom(id) or is_binary(id)) do
      unknown = Map.keys(Map.new(attrs)) -- (Method.__struct__() |> Map.keys())

      case unknown do
        [] -> {:ok, struct!(Method, Map.new(attrs))}
        extra -> {:error, %{reason: :unknown_method_fields, method: id, fields: Enum.sort(extra)}}
      end
    else
      {:error, %{reason: :missing_method_id, method: id}}
    end
  end

  defp build_method(other), do: {:error, %{reason: :invalid_method, value: other}}

  @authorities [:none, :observe, :select, :plan, :construct]

  @doc "Authority ceilings a task may declare. `:do` is never among them."
  @spec authorities() :: [atom()]
  def authorities, do: @authorities

  @doc """
  Full structural validation: unique ids, resolvable dependencies, terminal
  outcomes that are declared outcomes, acyclicity, parseable capabilities,
  authority at or below the `:construct` ceiling, and methods that only refer to
  declared tasks. Returns the first violation.
  """
  @spec validate(t()) :: :ok | {:error, map()}
  def validate(%__MODULE__{} = m) do
    with :ok <- check_unique(m.tasks),
         :ok <- check_dependencies(m.tasks),
         :ok <- check_terminal(m.tasks),
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

    {ready, pending} =
      deps
      |> Enum.split_with(fn {_id, d} -> MapSet.size(d) == 0 end)
      |> then(fn {ready, pending} -> {for({id, _d} <- ready, do: id), Map.new(pending)} end)

    dependents =
      Enum.reduce(deps, %{}, fn {id, d}, index ->
        Enum.reduce(d, index, fn dep, index ->
          case Map.fetch(index, dep) do
            :error -> Map.put(index, dep, [id])
            {:ok, ids} -> Map.put(index, dep, [id | ids])
          end
        end)
      end)

    kahn(:gb_sets.from_list(ready), pending, dependents, [])
  end

  # Greedy smallest-ready-first Kahn. `gb_sets` keeps the queue ordered, so the
  # emitted order is identical to re-scanning for the smallest ready id every
  # round, but each task is dequeued once: linear in tasks + dependencies
  # instead of quadratic on long dependency chains.
  defp kahn(queue, pending, dependents, acc) do
    if :gb_sets.is_empty(queue) do
      case map_size(pending) do
        0 ->
          {:ok, Enum.reverse(acc)}

        _ ->
          {:error, %{reason: :cyclic_dependencies, tasks: pending |> Map.keys() |> Enum.sort()}}
      end
    else
      {next, queue} = :gb_sets.take_smallest(queue)

      {queue, pending} =
        Enum.reduce(Map.get(dependents, next, []), {queue, pending}, fn id, {queue, pending} ->
          remaining = MapSet.delete(Map.fetch!(pending, id), next)
          pending = Map.put(pending, id, remaining)

          if MapSet.size(remaining) == 0,
            do: {:gb_sets.add(id, queue), pending},
            else: {queue, pending}
        end)

      kahn(queue, Map.delete(pending, next), dependents, [next | acc])
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
        terminal_outcomes: set(t.terminal_outcomes),
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

  # A terminal outcome must be a declared outcome: terminal_outcomes ⊆ outcomes
  # per task, in the same shape as check_dependencies/1.
  defp check_terminal(tasks) do
    bad =
      for t <- tasks,
          unknown = t.terminal_outcomes -- t.outcomes,
          unknown != [] do
        t.id
      end

    case bad do
      [] -> :ok
      bad -> {:error, %{reason: :unknown_terminal_outcomes, tasks: Enum.uniq(bad)}}
    end
  end
end

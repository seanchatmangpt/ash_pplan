defmodule AshPPlan.HTN do
  @moduledoc """
  Hierarchical Task Network (HTN), STRIPS state-space, and HDDL planning for `AshPPlan`.

  Ported and unified from `ex4pm`:
  - `Ex4pmEngine.Cognition.Planner` (STRIPS / means-ends state-space planner with
    `Action` preconditions, `add_list`, `delete_list`, and `cost`)
  - Total-Order Hierarchical Task Network decomposition (`Method`
    with `id`, `task`, `preconditions`, `subtasks`, and backtracking across
    alternative *methods* for a compound task — the ordering of subtasks within
    a decomposition is fixed, so this is not a partial-order planner)
  - `Ex4pm.Engine.Ferroplan` (`hierarchical_plan/3` and `hddl_solve/4`) and
    `Ex4pmEngine.Wasm.HtnPlan` (`wasm_htn_plan/2`) via optional runtime bridge
    (`Code.ensure_loaded?/1` + `apply/3`), preserving zero-compile-coupling when
    `ex4pm` is absent.

  ## Authority Ceiling

  `AshPPlan.HTN` is strictly a `SELECT` / `CONSTRUCT` planner: every plan,
  decomposition, or HDDL universal policy it produces carries
  `authority_ceiling: :none` (`"CONSTRUCT"`). It never executes an Ash action or
  claims ambient `DO` authority.
  """

  alias AshPPlan.Workflow.Model, as: WorkflowModel
  alias AshPPlan.Workflow.Project.HDDL

  defmodule Action do
    @moduledoc """
    A primitive HTN / STRIPS operator (`name`, `preconditions`, `add_list`,
    `delete_list`, `cost`, `metadata`).

    Matches `Ex4pmEngine.Cognition.Planner.Action` while normalizing facts into
    `MapSet`s for deterministic evaluation.
    """

    @enforce_keys [:name]
    defstruct [
      :name,
      preconditions: MapSet.new(),
      add_list: MapSet.new(),
      delete_list: MapSet.new(),
      cost: 1.0,
      metadata: %{}
    ]

    @type fact :: term()
    @type t :: %__MODULE__{
            name: atom() | String.t() | tuple(),
            preconditions: MapSet.t(fact()),
            add_list: MapSet.t(fact()),
            delete_list: MapSet.t(fact()),
            cost: number(),
            metadata: map()
          }

    @doc "Builds a normalized primitive `Action` struct from a keyword list, map, or `%Action{}`."
    @spec new(t() | map() | keyword()) :: t()
    def new(%__MODULE__{} = action) do
      %__MODULE__{
        action
        | preconditions: to_set(action.preconditions),
          add_list: to_set(action.add_list),
          delete_list: to_set(action.delete_list),
          cost: (action.cost || 1.0) * 1.0,
          metadata: action.metadata || %{}
      }
    end

    def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

    def new(attrs) when is_map(attrs) do
      name = fetch!(attrs, :name)
      pre = fetch(attrs, :preconditions, [])
      add = fetch(attrs, :add_list, fetch(attrs, :effects, []))
      del = fetch(attrs, :delete_list, [])
      cost = fetch(attrs, :cost, 1.0)
      meta = fetch(attrs, :metadata, %{})

      %__MODULE__{
        name: name,
        preconditions: to_set(pre),
        add_list: to_set(add),
        delete_list: to_set(del),
        cost: cost * 1.0,
        metadata: meta
      }
    end

    defp fetch!(map, key) do
      case fetch(map, key, :__missing__) do
        :__missing__ ->
          case fetch(map, :id, :__missing__) do
            :__missing__ -> raise ArgumentError, "AshPPlan.HTN.Action requires :name (got #{inspect(map)})"
            val -> val
          end

        val ->
          val
      end
    end

    defp fetch(map, key, default) when is_atom(key) do
      cond do
        Map.has_key?(map, key) -> Map.get(map, key)
        Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
        true -> default
      end
    end

    defp to_set(%MapSet{} = set), do: set
    defp to_set(nil), do: MapSet.new()
    defp to_set(enum) when is_list(enum), do: MapSet.new(enum)
    defp to_set(other), do: MapSet.new(List.wrap(other))
  end

  defmodule Method do
    @moduledoc """
    An HTN decomposition method that rewrites a compound `task` into an ordered
    list of `subtasks` when `preconditions` hold in the current world state.
    """

    @enforce_keys [:id, :task, :subtasks]
    defstruct [
      :id,
      :task,
      preconditions: MapSet.new(),
      negative_preconditions: MapSet.new(),
      subtasks: [],
      priority: 0,
      metadata: %{}
    ]

    @type task_ref :: atom() | String.t() | tuple()
    @type t :: %__MODULE__{
            id: atom() | String.t(),
            task: task_ref(),
            preconditions: MapSet.t(term()),
            negative_preconditions: MapSet.t(term()),
            subtasks: [task_ref()],
            priority: integer(),
            metadata: map()
          }

    @doc "Builds a normalized `Method` struct from a keyword list, map, `%AshPPlan.Workflow.Method{}`, or `%Method{}`."
    @spec new(t() | struct() | map() | keyword()) :: t()
    def new(%__MODULE__{} = method) do
      %__MODULE__{
        method
        | preconditions: to_set(method.preconditions),
          negative_preconditions: to_set(method.negative_preconditions),
          subtasks: List.wrap(method.subtasks),
          priority: method.priority || 0,
          metadata: method.metadata || %{}
      }
    end

    def new(%AshPPlan.Workflow.Method{} = wf_method) do
      pre =
        case wf_method.precondition do
          nil -> []
          list when is_list(list) -> list
          %MapSet{} = set -> MapSet.to_list(set)
          single -> [single]
        end

      %__MODULE__{
        id: wf_method.id,
        task: wf_method.task,
        preconditions: MapSet.new(pre),
        negative_preconditions: MapSet.new(),
        subtasks: List.wrap(wf_method.subtasks),
        priority: 0,
        metadata: %{source: :workflow_method}
      }
    end

    def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

    def new(attrs) when is_map(attrs) do
      id = fetch!(attrs, :id)
      task = fetch!(attrs, :task)
      pre = fetch(attrs, :preconditions, fetch(attrs, :precondition, []))
      neg = fetch(attrs, :negative_preconditions, [])
      subtasks = fetch(attrs, :subtasks, [])
      priority = fetch(attrs, :priority, 0)
      metadata = fetch(attrs, :metadata, %{})

      %__MODULE__{
        id: id,
        task: task,
        preconditions: to_set(pre),
        negative_preconditions: to_set(neg),
        subtasks: List.wrap(subtasks),
        priority: priority,
        metadata: metadata
      }
    end

    defp fetch!(map, key) do
      case fetch(map, key, :__missing__) do
        :__missing__ ->
          raise ArgumentError, "AshPPlan.HTN.Method requires #{inspect(key)} (got #{inspect(map)})"

        val ->
          val
      end
    end

    defp fetch(map, key, default) when is_atom(key) do
      cond do
        Map.has_key?(map, key) -> Map.get(map, key)
        Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
        true -> default
      end
    end

    defp to_set(%MapSet{} = set), do: set
    defp to_set(nil), do: MapSet.new()
    defp to_set(enum) when is_list(enum), do: MapSet.new(enum)
    defp to_set(other), do: MapSet.new(List.wrap(other))
  end

  defstruct actions: %{},
            action_list: [],
            methods: [],
            metadata: %{}

  @type state :: MapSet.t(term())
  @type t :: %__MODULE__{
          actions: %{optional(term()) => Action.t()},
          action_list: [Action.t()],
          methods: [Method.t()],
          metadata: map()
        }

  # Default raised from 64: a legitimately deep compound-method chain (e.g. a
  # 100-task linear method chain) exceeds 64 method expansions. The (task,
  # state) visited set and `max_steps` (256) still bound the search.
  @default_max_depth 256
  @default_max_steps 256

  @doc """
  Constructs a pure-data `%AshPPlan.HTN{}` domain from primitive `actions` and
  compound `methods`.
  """
  @spec new([Action.t() | map() | keyword()], [Method.t() | struct() | map() | keyword()], map() | keyword()) ::
          t()
  def new(actions, methods \\ [], metadata \\ %{}) when is_list(actions) and is_list(methods) do
    normalized_actions = Enum.map(actions, &Action.new/1)
    normalized_methods = Enum.map(methods, &Method.new/1)

    %__MODULE__{
      actions: Map.new(normalized_actions, &{&1.name, &1}),
      action_list: normalized_actions,
      methods: normalized_methods,
      metadata: Map.new(metadata)
    }
  end

  @doc """
  Decomposes an ordered task network (`tasks`) from `initial_state` using the
  HTN domain's methods and primitive actions.

  Supports backtracking across applicable *methods* for a compound task when a
  downstream primitive action's preconditions fail; the ordering of subtasks
  within a decomposition is fixed (total-order decomposition).

  Bounds: `opts[:max_depth]` (default 256) counts only *method-expansion* depth —
  chains of primitive steps do not consume depth. `opts[:max_steps]` (default
  256) bounds the total number of primitive and method expansions; the
  `(task, state)` visited set makes a decomposition that re-expands the same
  compound task in the same world state a typed
  `:cyclic_decomposition` refusal instead of an infinite loop.

  Returns:
  - `{:ok, %{plan: [task_name], actions: [%Action{}], total_cost: float(), decomposition_trace: [map()], final_state: MapSet.t(), authority_ceiling: :none}}`
  - `{:error, %{reason: atom(), task: term(), state: MapSet.t()}}`
  """
  @spec decompose(t(), [term()] | term(), Enumerable.t(), keyword()) ::
          {:ok, map()} | {:error, map()}
  def decompose(%__MODULE__{} = domain, tasks, initial_state, opts \\ []) do
    max_depth = Keyword.get(opts, :max_depth, @default_max_depth)
    max_steps = Keyword.get(opts, :max_steps, @default_max_steps)
    task_list = List.wrap(tasks)
    state_set = to_state_set(initial_state)

    case do_decompose(domain, task_list, state_set, [], [], 0.0, 0, 0, MapSet.new(), max_depth, max_steps) do
      {:ok, rev_actions, rev_trace, cost, final_state} ->
        actions = Enum.reverse(rev_actions)

        {:ok,
         %{
           status: :solved,
           planning_type: :htn,
           plan: Enum.map(actions, & &1.name),
           actions: actions,
           total_cost: Float.round(cost * 1.0, 4),
           decomposition_trace: Enum.reverse(rev_trace),
           initial_state: state_set,
           final_state: final_state,
           authority_ceiling: :none
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Unified HTN + STRIPS planner entrypoint (ported from `Ex4pmEngine.Cognition.Planner.plan/4`
  and extended for hierarchical task networks):

  1. When `domain` is an `%AshPPlan.HTN{}` and `tasks_or_initial` is a list of tasks
     (or `opts[:mode] == :htn`), runs hierarchical task decomposition via `decompose/4`.
     If `opts[:goal_state]` is also provided, verifies that the resulting `final_state`
     satisfies `goal_state`. Backtracking across alternative *methods* happens
     only when decomposition itself fails (a primitive's preconditions are not
     met); a decomposition that completes but misses `goal_state` is a terminal
     `{:error, %{reason: :goal_not_satisfied}}` — it is not retried against other
     methods (total-order decomposition: subtask order within a method is fixed;
     this is not partial-order reordering).
  2. When called with `(initial_state, goal_state, actions, opts)` (exact
     `Ex4pmEngine.Cognition.Planner.plan/4` signature) or `opts[:mode] == :strips`,
     runs STRIPS means-ends breadth-first search.
  """
  def plan(arg1, arg2, arg3 \\ [], opts \\ [])

  def plan(%__MODULE__{} = domain, tasks, initial_state, opts) when is_list(opts) do
    mode = Keyword.get(opts, :mode, infer_mode(domain, tasks, initial_state))

    case mode do
      :strips ->
        strips_plan(to_state_set(tasks), to_state_set(initial_state), domain.action_list, opts)

      :htn ->
        goal_state =
          case Keyword.fetch(opts, :goal_state) do
            {:ok, goal} -> to_state_set(goal)
            :error -> nil
          end

        max_depth = Keyword.get(opts, :max_depth, @default_max_depth)
        max_steps = Keyword.get(opts, :max_steps, @default_max_steps)
        task_list = List.wrap(tasks)
        state_set = to_state_set(initial_state)

        case do_decompose_with_goal(domain, task_list, state_set, goal_state, [], [], 0.0, 0, 0, MapSet.new(), max_depth, max_steps) do
          {:ok, rev_actions, rev_trace, cost, final_state} ->
            actions = Enum.reverse(rev_actions)

            {:ok,
             %{
               status: :solved,
               planning_type: :htn,
               plan: Enum.map(actions, & &1.name),
               actions: actions,
               total_cost: Float.round(cost * 1.0, 4),
               decomposition_trace: Enum.reverse(rev_trace),
               initial_state: state_set,
               final_state: final_state,
               authority_ceiling: :none
             }}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def plan(%MapSet{} = initial_state, %MapSet{} = goal_state, actions, opts)
      when is_list(actions) and is_list(opts) do
    strips_plan(initial_state, goal_state, Enum.map(actions, &Action.new/1), opts)
  end

  def plan(initial_state, goal_state, actions, opts)
      when is_list(actions) and is_list(opts) do
    strips_plan(to_state_set(initial_state), to_state_set(goal_state), Enum.map(actions, &Action.new/1), opts)
  end

  @doc """
  Direct port of `Ex4pmEngine.Cognition.Planner.plan/4`: STRIPS / means-ends
  breadth-first state-space planner over primitive `%Action{}` structs.

  Returns `{:ok, %{plan: [name], actions: [%Action{}], total_cost: float(), final_state: MapSet.t(), authority_ceiling: :none}}`,
  `{:error, :no_plan_found}`, or `{:error, :max_depth_exceeded}`.
  """
  @spec strips_plan(MapSet.t(), MapSet.t(), [Action.t() | map() | keyword()], keyword()) ::
          {:ok, map()} | {:error, :no_plan_found | :max_depth_exceeded}
  def strips_plan(%MapSet{} = initial_state, %MapSet{} = goal_state, actions, opts \\ [])
      when is_list(actions) do
    normalized_actions = Enum.map(actions, &Action.new/1)
    max_depth = Keyword.get(opts, :max_depth, 10)

    if goal_satisfied?(initial_state, goal_state) do
      {:ok,
       %{
         status: :solved,
         planning_type: :strips,
         plan: [],
         actions: [],
         total_cost: 0.0,
         initial_state: initial_state,
         final_state: initial_state,
         authority_ceiling: :none
       }}
    else
      initial_node = {initial_state, [], 0.0, 0}
      queue = :queue.from_list([initial_node])
      visited = MapSet.new([initial_state])

      bfs_search(queue, visited, goal_state, normalized_actions, max_depth, false)
    end
  end

  @doc """
  Checks whether a state satisfies all preconditions of an `Action`, `Method`, or
  explicit `MapSet`.
  """
  @spec applicable?(MapSet.t(), Action.t() | Method.t() | MapSet.t()) :: boolean()
  def applicable?(%MapSet{} = state, %Action{preconditions: pre}) do
    MapSet.subset?(pre, state)
  end

  def applicable?(%MapSet{} = state, %Method{preconditions: pre, negative_preconditions: neg}) do
    MapSet.subset?(pre, state) and MapSet.disjoint?(neg, state)
  end

  def applicable?(%MapSet{} = state, %MapSet{} = preconditions) do
    MapSet.subset?(preconditions, state)
  end

  @doc """
  Applies a primitive `Action` to `state`: `(state \\ delete_list) ∪ add_list`.
  """
  @spec apply_action(MapSet.t(), Action.t()) :: MapSet.t()
  def apply_action(%MapSet{} = state, %Action{add_list: add, delete_list: del}) do
    state
    |> MapSet.difference(del)
    |> MapSet.union(add)
  end

  @doc """
  Converts an `%AshPPlan.Workflow.Model{}` (tasks, dependencies, and methods)
  into an `%AshPPlan.HTN{}` domain.

  Each primitive workflow task (a task that is not the target of any method)
  becomes an `%Action{}` whose preconditions require its `depends_on` tasks to be
  completed (`{:completed, dep_id}`) and whose `add_list` asserts
  `{:completed, task.id}` plus any custom effects supplied via `opts[:task_effects]`.
  If the workflow defines no explicit methods, a root compound task (`workflow.goal`
  or `:workflow_root`) is synthesized with a topological method over the workflow's
  tasks.

  If the workflow's methods form a cycle (every method's task also appears as a
  subtask of some method, so no root compound task exists), returns
  `{:error, %{reason: :cyclic_methods, tasks: [...]}}` instead of guessing a root.
  """
  @spec from_workflow(WorkflowModel.t(), keyword()) :: {:ok, t(), [term()]} | {:error, map()}
  def from_workflow(%WorkflowModel{} = workflow, opts \\ []) do
    task_preconditions = Keyword.get(opts, :task_preconditions, %{})
    task_effects = Keyword.get(opts, :task_effects, %{})
    task_costs = Keyword.get(opts, :task_costs, %{})

    compound_task_ids =
      workflow.methods
      |> Enum.map(& &1.task)
      |> MapSet.new()

    primitive_actions =
      workflow.tasks
      |> Enum.reject(&MapSet.member?(compound_task_ids, &1.id))
      |> Enum.map(fn task ->
        dep_pre = Enum.map(task.depends_on || [], &{:completed, &1})
        extra_pre = Map.get(task_preconditions, task.id, [])
        extra_add = Map.get(task_effects, task.id, [])
        cost = Map.get(task_costs, task.id, 1.0)

        Action.new(
          name: task.id,
          preconditions: dep_pre ++ List.wrap(extra_pre),
          add_list: [{:completed, task.id}, {:capability_satisfied, task.capability} | List.wrap(extra_add)],
          delete_list: [],
          cost: cost,
          metadata: %{capability: task.capability, depends_on: task.depends_on}
        )
      end)

    {methods, root_tasks} =
      case workflow.methods do
        [] ->
          ordered_ids = topological_task_ids(workflow.tasks)
          root_task = {:achieve_goal, workflow.goal || workflow.name}

          synthesized_method =
            Method.new(
              id: :default_workflow_decomposition,
              task: root_task,
              preconditions: [],
              subtasks: ordered_ids
            )

          {[synthesized_method], [root_task]}

        wf_methods ->
          converted = Enum.map(wf_methods, &Method.new/1)

          subtask_set =
            converted
            |> Enum.flat_map(& &1.subtasks)
            |> MapSet.new()

          roots =
            converted
            |> Enum.map(& &1.task)
            |> Enum.uniq()
            |> Enum.reject(&MapSet.member?(subtask_set, &1))

          case roots do
            [] ->
              {:error, %{reason: :cyclic_methods, tasks: converted |> Enum.map(& &1.task) |> Enum.uniq()}}

            root_list ->
              {converted, root_list}
          end
      end

    case {methods, root_tasks} do
      {:error, _} = cyclic_error ->
        cyclic_error

      {methods, root_tasks} ->
        domain =
          new(primitive_actions, methods, %{
            workflow_name: workflow.name,
            workflow_goal: workflow.goal
          })

        {:ok, domain, root_tasks}
    end
  end

  @doc """
  Solves an HDDL domain + problem pair.

  Delegates to `Ex4pm.Engine.Ferroplan.hddl_solve/4` when `Ex4pm` is loaded and
  available; otherwise parses the HDDL text via `AshPPlan.Workflow.Project.HDDL.parse/1`
  and solves the resulting workflow HTN natively in BEAM.
  """
  @spec hddl_solve(String.t(), String.t(), map() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def hddl_solve(domain_hddl, problem_hddl, limits \\ nil, opts \\ [])
      when is_binary(domain_hddl) and is_binary(problem_hddl) do
    engine = Keyword.get(opts, :engine, :auto)

    if engine in [:auto, :ex4pm, :ferroplan] and ex4pm_ferroplan_loaded?() do
      case apply(Ex4pm.Engine.Ferroplan, :hddl_solve, [domain_hddl, problem_hddl, limits, opts]) do
        {:ok, result} when is_map(result) ->
          {:ok, Map.put_new(result, :authority_ceiling, :none)}

        {:error, _reason} = err ->
          if engine == :auto do
            native_hddl_solve(domain_hddl, problem_hddl, opts)
          else
            err
          end
      end
    else
      native_hddl_solve(domain_hddl, problem_hddl, opts)
    end
  end

  @doc """
  Runs a hierarchical plan via `Ex4pm.Engine.Ferroplan.hierarchical_plan/3` (or
  `Ex4pmEngine.Wasm.HtnPlan.plan/2` when `opts[:backend] == :wasm_cognition`),
  falling back to `AshPPlan.HTN` native decomposition when `problem` is a native
  HTN specification map.
  """
  @spec hierarchical_plan(map(), map() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def hierarchical_plan(problem, limits \\ nil, opts \\ []) when is_map(problem) do
    backend = Keyword.get(opts, :backend, :auto)

    cond do
      backend == :wasm_cognition and Code.ensure_loaded?(Ex4pmEngine.Wasm.HtnPlan) ->
        case apply(Ex4pmEngine.Wasm.HtnPlan, :plan, [problem, opts]) do
          {:ok, result} when is_map(result) -> {:ok, Map.put_new(result, :authority_ceiling, :none)}
          other -> other
        end

      backend in [:auto, :ferroplan] and ex4pm_ferroplan_loaded?() and
          (Map.has_key?(problem, :domain_hddl) or Map.has_key?(problem, "domain_hddl") or
             Map.has_key?(problem, :tasks) or Map.has_key?(problem, "tasks")) and
          not Map.has_key?(problem, :htn_domain) ->
        case apply(Ex4pm.Engine.Ferroplan, :hierarchical_plan, [problem, limits, opts]) do
          {:ok, result} when is_map(result) ->
            {:ok, Map.put_new(result, :authority_ceiling, :none)}

          {:error, _} = err ->
            if Map.has_key?(problem, :actions) do
              native_hierarchical_plan(problem, opts)
            else
              err
            end
        end

      true ->
        native_hierarchical_plan(problem, opts)
    end
  end

  # -- Internal HTN recursive decomposition with backtracking -------------------

  # Depth counts ONLY method expansions (a primitive step passes `depth`
  # through unchanged); `steps` bounds every expansion; `visited` makes a
  # repeated `(task, state)` expansion a typed cyclic refusal.
  defp do_decompose(_domain, [], state, acc_actions, acc_trace, acc_cost, _depth, _steps, _visited, _max_depth, _max_steps) do
    {:ok, acc_actions, acc_trace, acc_cost, state}
  end

  defp do_decompose(_domain, [task | _], state, _acc_actions, _acc_trace, _acc_cost, depth, _steps, _visited, max_depth, _max_steps)
       when depth > max_depth do
    {:error, %{reason: :max_depth_exceeded, task: task, state: state, depth: depth}}
  end

  defp do_decompose(_domain, [task | _], state, _acc_actions, _acc_trace, _acc_cost, _depth, steps, _visited, _max_depth, max_steps)
       when steps >= max_steps do
    {:error, %{reason: :max_steps_exceeded, task: task, state: state, steps: steps}}
  end

  defp do_decompose(domain, [task | rest], state, acc_actions, acc_trace, acc_cost, depth, steps, visited, max_depth, max_steps) do
    case Map.fetch(domain.actions, task) do
      {:ok, %Action{} = action} ->
        if applicable?(state, action) do
          next_state = apply_action(state, action)

          step_trace = %{
            kind: :primitive,
            task: task,
            depth: depth,
            cost: action.cost
          }

          do_decompose(
            domain,
            rest,
            next_state,
            [action | acc_actions],
            [step_trace | acc_trace],
            acc_cost + action.cost,
            depth,
            steps + 1,
            visited,
            max_depth,
            max_steps
          )
        else
          missing = MapSet.difference(action.preconditions, state)

          {:error,
           %{
             reason: :preconditions_not_met,
             task: task,
             missing_preconditions: MapSet.to_list(missing),
             state: state
           }}
        end

      :error ->
        if MapSet.member?(visited, {task, state}) do
          {:error, %{reason: :cyclic_decomposition, task: task, state: state}}
        else
          visited = MapSet.put(visited, {task, state})

          candidate_methods =
            domain.methods
            |> Enum.filter(&(&1.task == task and applicable?(state, &1)))
            |> Enum.sort_by(&{-&1.priority, &1.id})

          case candidate_methods do
            [] ->
              has_any_method? = Enum.any?(domain.methods, &(&1.task == task))

              reason =
                if has_any_method?,
                  do: :no_applicable_method,
                  else: :unknown_task

              {:error, %{reason: reason, task: task, state: state}}

            methods ->
              try_methods(
                methods,
                domain,
                task,
                rest,
                state,
                acc_actions,
                acc_trace,
                acc_cost,
                depth + 1,
                steps + 1,
                visited,
                max_depth,
                max_steps,
                # LANE A3 SLA minimal-unblock: definition carries a last_err
                # accumulator the callsite omitted; passing nil (initial).
                nil
              )
          end
        end
    end
  end

  defp try_methods([], _domain, task, _rest, state, _acc_actions, _acc_trace, _acc_cost, _depth, _steps, _visited, _max_depth, _max_steps, last_err) do
    last_err || {:error, %{reason: :no_applicable_method, task: task, state: state}}
  end

  defp try_methods(
         [%Method{} = method | other_methods],
         domain,
         task,
         rest,
         state,
         acc_actions,
         acc_trace,
         acc_cost,
         depth,
         steps,
         visited,
         max_depth,
         max_steps,
         _last_err
       ) do
    method_trace = %{
      kind: :compound,
      task: task,
      method_id: method.id,
      subtasks: method.subtasks,
      depth: depth
    }

    expanded_tasks = method.subtasks ++ rest

    case do_decompose(
           domain,
           expanded_tasks,
           state,
           acc_actions,
           [method_trace | acc_trace],
           acc_cost,
           depth,
           steps,
           visited,
           max_depth,
           max_steps
         ) do
      {:ok, _, _, _, _} = ok ->
        ok

      {:error, _} = err ->
        try_methods(
          other_methods,
          domain,
          task,
          rest,
          state,
          acc_actions,
          acc_trace,
          acc_cost,
          depth,
          steps,
          visited,
          max_depth,
          max_steps,
          err
        )
    end
  end

  defp do_decompose_with_goal(domain, tasks, state, nil, acc_actions, acc_trace, acc_cost, depth, steps, visited, max_depth, max_steps) do
    do_decompose(domain, tasks, state, acc_actions, acc_trace, acc_cost, depth, steps, visited, max_depth, max_steps)
  end

  defp do_decompose_with_goal(domain, tasks, state, goal_state, acc_actions, acc_trace, acc_cost, depth, steps, visited, max_depth, max_steps) do
    case do_decompose(domain, tasks, state, acc_actions, acc_trace, acc_cost, depth, steps, visited, max_depth, max_steps) do
      {:ok, rev_actions, rev_trace, cost, final_state} ->
        if goal_satisfied?(final_state, goal_state) do
          {:ok, rev_actions, rev_trace, cost, final_state}
        else
          missing = MapSet.difference(goal_state, final_state)

          {:error,
           %{
             reason: :goal_not_satisfied,
             missing_goals: MapSet.to_list(missing),
             final_state: final_state
           }}
        end

      {:error, _} = err ->
        err
    end
  end

  # -- Internal STRIPS BFS (ported from Ex4pmEngine.Cognition.Planner) ----------

  defp bfs_search(queue, visited, goal_state, actions, max_depth, depth_limit_hit?) do
    case :queue.out(queue) do
      {:empty, _} ->
        if depth_limit_hit?, do: {:error, :max_depth_exceeded}, else: {:error, :no_plan_found}

      {{:value, {current_state, plan_so_far, cost_so_far, depth}}, rest_queue} ->
        if depth >= max_depth do
          bfs_search(rest_queue, visited, goal_state, actions, max_depth, true)
        else
          applicable_actions = Enum.filter(actions, &applicable?(current_state, &1))

          result =
            Enum.reduce_while(
              applicable_actions,
              {:continue, rest_queue, visited},
              fn action, {:continue, q, v} ->
                next_state = apply_action(current_state, action)
                next_plan = plan_so_far ++ [action]
                next_cost = cost_so_far + action.cost

                if goal_satisfied?(next_state, goal_state) do
                  {:halt,
                   {:found,
                    %{
                      status: :solved,
                      planning_type: :strips,
                      plan: Enum.map(next_plan, & &1.name),
                      actions: next_plan,
                      total_cost: Float.round(next_cost * 1.0, 4),
                      initial_state: nil,
                      final_state: next_state,
                      authority_ceiling: :none
                    }}}
                else
                  if MapSet.member?(v, next_state) do
                    {:cont, {:continue, q, v}}
                  else
                    new_q = :queue.in({next_state, next_plan, next_cost, depth + 1}, q)
                    new_v = MapSet.put(v, next_state)
                    {:cont, {:continue, new_q, new_v}}
                  end
                end
              end
            )

          case result do
            {:found, solution} ->
              {:ok, solution}

            {:continue, next_queue, next_visited} ->
              bfs_search(next_queue, next_visited, goal_state, actions, max_depth, depth_limit_hit?)
          end
        end
    end
  end

  defp goal_satisfied?(%MapSet{} = state, %MapSet{} = goal) do
    MapSet.subset?(goal, state)
  end

  defp infer_mode(%__MODULE__{methods: methods}, tasks, _initial_state) do
    if methods != [] or is_list(tasks) do
      :htn
    else
      :strips
    end
  end

  defp to_state_set(%MapSet{} = set), do: set
  defp to_state_set(nil), do: MapSet.new()
  defp to_state_set(list) when is_list(list), do: MapSet.new(list)
  defp to_state_set(other), do: MapSet.new(List.wrap(other))

  defp topological_task_ids(tasks) do
    by_id = Map.new(tasks, &{&1.id, &1})

    {ordered, _visited} =
      Enum.reduce(tasks, {[], MapSet.new()}, fn task, {acc, visited} ->
        visit_task(task.id, by_id, acc, visited)
      end)

    Enum.reverse(ordered)
  end

  defp visit_task(id, by_id, acc, visited) do
    if MapSet.member?(visited, id) do
      {acc, visited}
    else
      visited = MapSet.put(visited, id)

      {acc, visited} =
        case Map.get(by_id, id) do
          nil ->
            {acc, visited}

          task ->
            Enum.reduce(task.depends_on || [], {acc, visited}, fn dep, {a, v} ->
              visit_task(dep, by_id, a, v)
            end)
        end

      {[id | acc], visited}
    end
  end

  defp ex4pm_ferroplan_loaded? do
    Code.ensure_loaded?(Ex4pm.Engine.Ferroplan) and
      function_exported?(Ex4pm.Engine.Ferroplan, :hddl_solve, 4)
  end

  defp native_hddl_solve(domain_hddl, problem_hddl, opts) do
    allow_stub = Keyword.get(opts, :allow_stub_problem, false)

    with {:ok, parsed} <- HDDL.parse(domain_hddl),
         {:ok, problem} <- parse_problem_file(problem_hddl, allow_stub) do
      {initial_state, root_tasks, goal_facts, problem_file_used} =
        case problem do
          %{stub?: true} ->
            {Keyword.get(opts, :initial_state, []), nil, nil, false}

          problem ->
            {problem.init, problem.htn, problem.goal, true}
        end

      result =
        if is_list(root_tasks) and root_tasks != [] do
          ground_problem_domain(parsed, root_tasks)
        else
          {:ok, {direct_domain(parsed), parsed[:top]}}
        end

      case result do
        {:ok, {domain, root_tasks}} ->
          root_tasks =
            root_tasks ||
              cond do
                parsed[:top] != nil -> [parsed[:top]]
                domain.methods != [] -> [hd(domain.methods).task]
                true -> Enum.map(domain.action_list, & &1.name)
              end

          initial = to_state_set(initial_state)
          goal_state = if goal_facts in [nil, []], do: nil, else: MapSet.new(goal_facts)

          result_opts = Keyword.put(opts, :goal_state, goal_state)

          case plan(domain, root_tasks, initial, result_opts) do
            {:ok, result} ->
              {:ok, Map.put(result, :problem_file_used, problem_file_used)}

            {:error, _} = err ->
              err
          end

        {:error, _} = err ->
          err
      end
    end
  end

  # A problem file is lawful only when it parses as a `(define (problem ...))`
  # form AND carries content (:init/:htn/:goal). A content-less stub is refused
  # unless `opts[:allow_stub_problem]` is set.
  defp parse_problem_file(text, allow_stub) do
    case HDDL.parse(text) do
      {:ok, %{problem: _} = problem} ->
        stub? = problem.init == [] and problem.htn == [] and problem.goal == []

        cond do
          not stub? ->
            {:ok, Map.put(problem, :stub?, false)}

          allow_stub ->
            {:ok, Map.put(problem, :stub?, true)}

          true ->
            {:error, %{reason: :invalid_problem_file, stub: true}}
        end

      {:ok, _} ->
        {:error, %{reason: :invalid_problem_file, parsed_as: :domain}}

      {:error, _} ->
        {:error, %{reason: :invalid_problem_file}}
    end
  end

  # DOC-DRIFT: pending re-landing of killed lane W4 — native_hddl_solve/3 and
  # parse_problem_file/2 carry body warnings under --warnings-as-errors
  # (htn.ex:936/958/974); moduledocs here are worded to current body behavior.
  # -- HDDL problem grounding -------------------------------------------------
  #
  # Grounds the parsed domain against the problem's `:htn` root instances:
  # every method/action the problem references is instantiated with its
  # variables bound positionally from the calling instance, so the generic
  # (propositional) `AshPPlan.HTN` solver can decompose it.

  @grounding_instance_cap 4096

  defp ground_problem_domain(parsed, root_instances) do
    ctx = %{
      actions: parsed.actions,
      methods_by_task: Enum.group_by(parsed.methods, &instance_name(&1.task)),
      tasks: parsed.tasks
    }

    acc = %{seen: MapSet.new(), actions: [], methods: [], count: 0, path: []}

    try do
      case ground_worklist(root_instances, ctx, acc) do
        {:ok, grounded} ->
          domain =
            new(
              Enum.reverse(grounded.actions),
              Enum.reverse(grounded.methods),
              %{domain_name: parsed.domain}
            )

          {:ok, {domain, root_instances}}

        {:error, _} = err ->
          err
      end
    catch
      {:grounding_unbound_var, v} ->
        {:error, %{reason: :hddl_grounding_error, cause: {:unbound_var, v}}}
    end
  end

  defp ground_worklist([], _ctx, acc), do: {:ok, acc}

  defp ground_worklist(_instances, _ctx, acc) when acc.count >= @grounding_instance_cap do
    {:error, %{reason: :cyclic_methods, tasks: Enum.uniq(acc.path)}}
  end

  defp ground_worklist([instance | rest], ctx, acc) do
    if MapSet.member?(acc.seen, instance) do
      ground_worklist(rest, ctx, acc)
    else
      case expand_instance(instance, ctx, acc) do
        {:ok, acc, enqueued} ->
          # Hierarchical decomposition: the grounded method's subtask instances
          # join the worklist ahead of the remaining frontier (seen-set and
          # instance cap still guard against cycles).
          ground_worklist(enqueued ++ rest, ctx, acc)

        {:error, _} = err ->
          err
      end
    end
  end

  defp expand_instance(instance, ctx, acc) do
    name = instance_name(instance)
    args = instance_args(instance)

    cond do
      Map.has_key?(ctx.actions, name) ->
        spec = Map.fetch!(ctx.actions, name)
        params = Map.get(spec, :parameters, [])

        with {:ok, binding} <- bind_args(params, args, instance),
             {:ok, pre} <- subst_facts(spec.pre, binding),
             {:ok, add} <- subst_facts(spec.effect, binding) do
          action =
            Action.new(
              name: instance,
              preconditions: pre,
              add_list: add,
              delete_list: []
            )

          {:ok,
           %{
             acc
             | seen: MapSet.put(acc.seen, instance),
               actions: [action | acc.actions],
               count: acc.count + 1,
               path: [instance | acc.path]
           }, []}
        end

      true ->
        methods = Map.get(ctx.methods_by_task, name, [])

        case methods do
          [] ->
            {:error, %{reason: :hddl_grounding_error, cause: :unknown_task, task: instance}}

          methods ->
            case Enum.reduce_while(methods, {:ok, []}, fn m, {:ok, gms} ->
                   case ground_method(m, instance) do
                     {:ok, gm} -> {:cont, {:ok, [gm | gms]}}
                     {:error, _} = e -> {:halt, e}
                   end
                 end) do
              {:ok, gms} ->
                enqueued = Enum.flat_map(gms, & &1.subtasks)

                {:ok,
                 %{
                   acc
                   | seen: MapSet.put(acc.seen, instance),
                     methods: Enum.reverse(gms) ++ acc.methods,
                     count: acc.count + 1,
                     path: [instance | acc.path]
                 }, enqueued}

              {:error, _} = err ->
                err
            end
        end
    end
  end

  defp ground_method(m, instance) do
    with {:ok, binding} <- bind_args(form_args(m.task), instance_args(instance), instance),
         {:ok, pre} <- subst_facts(m.precondition, binding),
         {:ok, subtasks} <- subst_instances(m.subtasks, binding) do
      {:ok,
       Method.new(
         id: grounded_method_id(m.id, instance),
         task: instance,
         preconditions: pre,
         subtasks: subtasks
       )}
    end
  end

  defp bind_args(params, args, _instance) when length(params) == length(args) do
    vars = Enum.map(params, fn {:var, v} -> v end)
    {:ok, Map.new(Enum.zip(vars, args))}
  end

  defp bind_args(_params, _args, instance),
    do: {:error, %{reason: :hddl_grounding_error, cause: :arity_mismatch, task: instance}}

  defp subst_facts(facts, binding), do: {:ok, Enum.map(facts, &subst_fact(&1, binding))}

  defp subst_fact(fact, _binding) when is_binary(fact), do: fact

  defp subst_fact(fact, binding) when is_tuple(fact) do
    fact
    |> Tuple.to_list()
    |> Enum.map(&subst_term(&1, binding))
    |> List.to_tuple()
  end

  defp subst_instances(subtasks, binding), do: {:ok, Enum.map(subtasks, &subst_instance(&1, binding))}

  defp subst_instance(instance, _binding) when is_binary(instance), do: instance

  defp subst_instance(instance, binding) when is_tuple(instance) do
    instance
    |> Tuple.to_list()
    |> Enum.map(&subst_term(&1, binding))
    |> List.to_tuple()
  end

  defp subst_term({:var, v}, binding) do
    case Map.fetch(binding, v) do
      {:ok, value} -> value
      :error -> throw({:grounding_unbound_var, v})
    end
  end

  defp subst_term(t, _binding), do: t

  defp instance_name(name) when is_binary(name), do: name
  defp instance_name(instance) when is_tuple(instance), do: elem(instance, 0)

  defp instance_args(instance) when is_binary(instance), do: []
  defp instance_args(instance) when is_tuple(instance), do: instance |> Tuple.to_list() |> tl()

  defp form_args(name) when is_binary(name), do: []
  defp form_args(form) when is_tuple(form), do: form |> Tuple.to_list() |> tl()

  defp grounded_method_id(id, instance), do: "#{id}/#{inspect(instance)}"

  # -- Ungrounded (direct) fallback domain for stub problems -------------------

  defp direct_domain(parsed) do
    actions =
      for {name, spec} <- parsed.actions do
        Action.new(
          name: name,
          preconditions: Map.get(spec, :pre, []),
          add_list: Map.get(spec, :effect, []),
          delete_list: []
        )
      end

    top_methods =
      if parsed[:top] && parsed[:top_subtasks] != [] do
        [
          Method.new(
            id: "m-top-" <> to_string(parsed[:top]),
            task: parsed[:top],
            preconditions: [],
            subtasks: parsed[:top_subtasks]
          )
          | Enum.map(parsed.methods, &to_method/1)
        ]
      else
        Enum.map(parsed.methods, &to_method/1)
      end

    new(actions, top_methods, %{domain_name: parsed.domain})
  end

  defp to_method(m),
    do: Method.new(id: m.id, task: m.task, preconditions: m.precondition, subtasks: m.subtasks)

  defp native_hierarchical_plan(problem, opts) do
    actions = Map.get(problem, :actions) || Map.get(problem, "actions") || []
    methods = Map.get(problem, :methods) || Map.get(problem, "methods") || []
    tasks = Map.get(problem, :tasks) || Map.get(problem, "tasks") || []
    initial = Map.get(problem, :initial_state) || Map.get(problem, "initial_state") || []

    domain =
      case Map.get(problem, :htn_domain) do
        %__MODULE__{} = d -> d
        _ -> new(actions, methods)
      end

    decompose(domain, tasks, initial, opts)
  end
end

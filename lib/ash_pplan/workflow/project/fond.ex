defmodule AshPPlan.Workflow.Project.FOND do
  @moduledoc """
  Projects a workflow model's task outcome topology into a FOND domain.

  A FOND state is the sorted list of completed task ids. The action
  `{:run, task}` is admitted once every dependency of `task` is complete. Each
  task outcome is one nondeterministic branch: the first success-like outcome
  (`"success"`, else the first declared outcome) completes the task, every other
  live (non-terminal) outcome is a retry branch that leaves the state unchanged.
  A task may declare `terminal_outcomes` — outcomes that end the run, such as a
  `"BLOCKED"` refusal — which contribute no branch; a task that declares
  outcomes and declares every one of them terminal contributes no action at
  all, leaving its state with an empty action map (a legal, losing FOND state).
  Goal is the state where all tasks are complete.

  The transition map is built by breadth-first search forward from the initial
  state over admitted actions and their branch successors, so only reachable
  states are projected (the previous power-set walk admitted every subset). A
  visited check at dequeue dedupes retry self-loops, so cyclic retry branches
  terminate.

  A policy is synthesized with `AshPPlan.synthesize_policy/3` when the domain is
  solvable. `unsupported` lists every `{task, outcome}` that no declared
  evidence can observe, so no outcome is silently assumed observable.

  Render only: no authority is granted (ceiling `:construct`).
  """

  alias AshPPlan.Workflow.Model

  @type result :: %{
          domain: AshPPlan.FOND.t(),
          initial: [term()],
          policy: map() | nil,
          mode: :strong | :strong_cyclic,
          refusal: term() | nil,
          observable: [{term(), term()}],
          unsupported: [{term(), term()}]
        }

  @spec project(Model.t(), keyword()) :: {:ok, result()} | {:error, map()}
  def project(model, opts \\ [])

  def project(%Model{} = model, opts) do
    mode = Keyword.get(opts, :mode, :strong_cyclic)

    with :ok <- Model.validate(model),
         {:ok, order} <- Model.topological_order(model),
         {:ok, domain} <- AshPPlan.fond_domain(transitions(model, order), [Enum.sort(order)]) do
      initial = []

      {policy, refusal} =
        case AshPPlan.synthesize_policy(domain, initial, mode) do
          {:ok, policy} -> {policy, nil}
          {:error, reason} -> {nil, reason}
        end

      {observable, unsupported} = split_outcomes(model)

      {:ok,
       %{
         domain: domain,
         initial: initial,
         policy: policy,
         mode: mode,
         refusal: refusal,
         observable: observable,
         unsupported: unsupported
       }}
    end
  end

  def project(other, _opts), do: {:error, %{reason: :not_a_model, value: other}}

  @doc "Outcomes of every task, split into observable (task declares evidence) and unsupported."
  @spec split_outcomes(Model.t()) :: {[{term(), term()}], [{term(), term()}]}
  def split_outcomes(%Model{tasks: tasks}) do
    pairs = for t <- tasks, o <- t.outcomes, do: {t, o}
    {obs, unsup} = Enum.split_with(pairs, fn {t, _o} -> t.evidence != [] end)
    {Enum.map(obs, fn {t, o} -> {t.id, o} end), Enum.map(unsup, fn {t, o} -> {t.id, o} end)}
  end

  defp transitions(%Model{tasks: tasks}, _order) do
    by_id = Map.new(tasks, &{&1.id, &1})

    dependents =
      Enum.reduce(tasks, %{}, fn t, acc ->
        Enum.reduce(t.depends_on, acc, fn dep, acc ->
          Map.update(acc, dep, [t.id], &[t.id | &1])
        end)
      end)

    initial =
      for t <- tasks, t.depends_on == [], branches(t, [], []) != [], into: %{} do
        {{:run, t.id}, branches(t, [], [])}
      end

    bfs(:queue.from_list([{[], initial}]), by_id, dependents, %{})
  end

  # Breadth-first from the initial state `[]` over admitted actions and their
  # branch successors. The visited set is the relation map itself, checked at
  # dequeue, so a state enqueued twice (a retry branch re-reaching an ancestor)
  # is expanded once and retry self-loops terminate. Each queue entry carries
  # the parent's action set, so a successor's action set is derived
  # incrementally — drop the completed task's action, re-render the surviving
  # actions' branches at the successor, add the newly ready dependents — making
  # the walk linear in the projected relation instead of a per-state scan of
  # every task. The derivation is path-independent: an action is admitted at a
  # state exactly when its dependencies are complete, whichever parent first
  # reaches the state.
  defp bfs(queue, by_id, dependents, acc) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        acc

      {{:value, {state, actions}}, queue} ->
        if Map.has_key?(acc, state) do
          bfs(queue, by_id, dependents, acc)
        else
          queue = enqueue_successors(actions, queue, by_id, dependents)
          bfs(queue, by_id, dependents, Map.put(acc, state, actions))
        end
    end
  end

  # Branch structure is `[forward]` or `[forward, retry]` by construction: the
  # retry branch re-reaches the state itself and is deduped at dequeue, so only
  # the forward head is ever enqueued.
  defp enqueue_successors(actions, queue, by_id, dependents) do
    Enum.reduce(actions, queue, fn {{:run, id}, [next_state | _retry]}, queue ->
      successor = successor_actions(next_state, id, actions, by_id, dependents)
      :queue.in({next_state, successor}, queue)
    end)
  end

  # The successor's admitted actions, derived from the parent's: the completed
  # task's action is dropped, every surviving action's branches are re-rendered
  # at the successor state, and only the completed task's dependents are checked
  # for newly ready admission (completion is the only event that can change
  # readiness).
  defp successor_actions(next, completed_id, actions, by_id, dependents) do
    # The descending twin of `next` makes the common branch construction a flat
    # cons; see insert/3.
    desc = :lists.reverse(next)

    kept =
      actions
      |> Map.delete({:run, completed_id})
      |> Map.new(fn {action, _branches} ->
        {:run, id} = action
        {action, branches(Map.fetch!(by_id, id), next, desc)}
      end)

    newly_ready =
      dependents
      |> Map.get(completed_id, [])
      |> Enum.filter(fn id ->
        # No `id not in next` guard: in a reachable state a dependent of the
        # just-completed task cannot itself be complete — it would have needed
        # this task's completion first.
        Enum.all?(Map.fetch!(by_id, id).depends_on, &(&1 in next))
      end)
      |> Map.new(fn id ->
        {{:run, id}, branches(Map.fetch!(by_id, id), next, desc)}
      end)

    # an all-terminal task contributes no action wherever it would be admitted
    Map.merge(kept, newly_ready)
    |> Map.reject(fn {_action, branches} -> branches == [] end)
  end

  # A task's live outcomes are the non-terminal ones. The first live outcome
  # completes the task; every further live outcome is a retry. With one live
  # outcome the action is deterministic. A task that declares outcomes and
  # declares every one of them terminal contributes no branch: its action is
  # omitted downstream (the FOND kernel refuses empty outcome lists), leaving
  # the state with an empty action map (legal, losing). A task with no declared
  # outcomes at all stays deterministic — the pre-terminal behavior.
  defp branches(task, state, desc) do
    {next, _next_desc} = insert(task.id, state, desc)

    case Enum.reject(task.outcomes, &(&1 in task.terminal_outcomes)) do
      [] -> if(task.outcomes == [], do: [next], else: [])
      [_only] -> [next]
      _live ->
        if success_like(task.outcomes, task.terminal_outcomes), do: [next, state], else: [next]
    end
  end

  # States are sorted task-id lists; the sortedness must survive inserting the
  # one newly completed id. The twin `desc` (descending) representation makes
  # the common case — the new id sorts after every completed id — a flat cons
  # plus a flat `++`; only a mid-list insert walks (and both halves of that
  # walk are charged once, not per closure). Ordering is plain term order, the
  # same order `Enum.sort` gave the pre-BFS projection.
  defp insert(id, asc, [max | _] = desc) when id > max, do: {asc ++ [id], [id | desc]}
  defp insert(id, _asc, []), do: {[id], [id]}

  defp insert(id, _asc, desc) do
    next_desc = insert_desc(id, desc)
    {:lists.reverse(next_desc), next_desc}
  end

  defp insert_desc(id, [h | _] = list) when id > h, do: [id | list]
  defp insert_desc(id, [h | t]), do: [h | insert_desc(id, t)]
  defp insert_desc(id, []), do: [id]

  # A task is success-like when at least one declared outcome is live (not a
  # terminal declaration).
  defp success_like(outcomes, terminal), do: Enum.any?(outcomes, &(&1 not in terminal))
end

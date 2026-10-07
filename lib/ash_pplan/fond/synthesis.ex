defmodule AshPPlan.FOND.Synthesis do
  @moduledoc """
  Strong and strong-cyclic policy synthesis over an explicit `AshPPlan.FOND`
  domain.

  `AshPPlan.FOND.validate_policy/4` checks a candidate policy. This module
  constructs one, using the classic fixpoint characterisations of the two
  solution classes (Cimatti, Pistore, Roveri and Traverso, "Weak, strong, and
  strong cyclic planning via symbolic model checking", AIJ 2003), evaluated
  explicitly over the finite transition relation:

    * `:strong` - the backward attractor of the goal set. A non-goal state
      joins layer `k + 1` when some admitted action has *every*
      nondeterministic outcome inside layers `0..k`. The action recorded for a
      state is the one that admitted it, so every policy step strictly lowers
      the layer rank and no execution can cycle.

    * `:strong_cyclic` - the greatest fixpoint `S` of states that retain a path
      to a goal using only *policy-closed* actions (actions whose outcomes all
      stay in `S`). Each outer round prunes actions that can leave `S`, then
      keeps only the states that can still reach a goal through the remaining
      actions (the path-to-goal pruning). The recorded action for a state is
      the one that first gave it a goal path, so every reachable policy state
      has a strictly shorter path to a goal under the fairness assumption.

  Synthesis is pure and deterministic: states and actions are visited in
  Erlang term order, and ties are broken by the smallest admitted action. The
  returned policy is restricted to the non-goal states reachable from
  `initial` under that policy, so it is exactly the input
  `AshPPlan.FOND.validate_policy/4` needs.

  Cost: the strong attractor is linear in the transition relation. Each
  strong-cyclic pruning round is linear too; the number of rounds is bounded
  by the number of states, so the worst case is `O(states * edges)`, the usual
  bound for explicit strong-cyclic synthesis.

  Refusals are typed:

    * `{:error, {:unsolvable, mode, witness_states}}` - no policy of the
      requested class exists from `initial`. `witness_states` is the sorted
      list of states reachable from `initial` under *any* action choice that
      lie outside the winning region. It always contains `initial`.
    * `{:error, {:unknown_initial_state, initial}}`
    * `{:error, {:invalid_mode, mode}}`
    * `{:error, {:invalid_domain, term}}` - including a hand-built
      `%AshPPlan.FOND{}` that violates the invariants `AshPPlan.FOND.new/2`
      establishes (see `AshPPlan.FOND.check/1`)

  Synthesis selects policy structure only. It never calls Reactor, Ash
  actions, jobs, queues, or schedulers, and a synthesized policy carries no
  actuation authority.
  """

  alias AshPPlan.FOND

  @modes [:strong, :strong_cyclic]

  @type refusal ::
          {:unsolvable, FOND.mode(), [FOND.state()]}
          | {:unknown_initial_state, FOND.state()}
          | {:invalid_mode, term()}
          | {:invalid_domain, term()}

  @doc """
  Synthesizes a `:strong` or `:strong_cyclic` policy from `initial`.

  Every `{:ok, policy}` result satisfies
  `AshPPlan.FOND.validate_policy(domain, policy, initial, mode) == {:ok, _}`.
  """
  @spec synthesize(FOND.t(), FOND.state(), FOND.mode()) ::
          {:ok, FOND.policy()} | {:error, refusal()}
  def synthesize(domain, initial, mode \\ :strong_cyclic)

  def synthesize(%FOND{} = domain, initial, mode) when mode in @modes do
    with :ok <- check_domain(domain) do
      synthesize_checked(domain, initial, mode)
    end
  end

  def synthesize(%FOND{}, _initial, mode), do: {:error, {:invalid_mode, mode}}
  def synthesize(domain, _initial, _mode), do: {:error, {:invalid_domain, domain}}

  defp synthesize_checked(domain, initial, mode) do
    if MapSet.member?(domain.states, initial) do
      {winning, policy} = winning_region(domain, mode)

      if MapSet.member?(winning, initial) do
        {:ok, restrict_to_reachable(domain, policy, initial)}
      else
        {:error, {:unsolvable, mode, witness_states(domain, winning, initial)}}
      end
    else
      {:error, {:unknown_initial_state, initial}}
    end
  end

  @doc """
  Returns the sorted winning region for `mode`: every state from which a
  policy of that class exists (goal states included).
  """
  @spec solvable_states(FOND.t(), FOND.mode()) :: {:ok, [FOND.state()]} | {:error, refusal()}
  def solvable_states(%FOND{} = domain, mode) when mode in @modes do
    with :ok <- check_domain(domain) do
      {winning, _policy} = winning_region(domain, mode)
      {:ok, winning |> MapSet.to_list() |> Enum.sort()}
    end
  end

  def solvable_states(%FOND{}, mode), do: {:error, {:invalid_mode, mode}}
  def solvable_states(domain, _mode), do: {:error, {:invalid_domain, domain}}

  # A hand-built `%FOND{}` can bypass `FOND.new/2`; an action with no outcomes
  # would then be vacuously "all outcomes winning". Refuse it up front.
  defp check_domain(domain) do
    case FOND.check(domain) do
      :ok -> :ok
      {:error, error} -> {:error, {:invalid_domain, error}}
    end
  end

  # -- winning regions -------------------------------------------------------
  #
  # Both regions are computed with worklists over a predecessor index of
  # `{state, action}` edges built once per domain, so a layer only touches the
  # edges into the states that joined the previous layer. The layer semantics
  # (and therefore the chosen actions) are exactly those of the naive
  # "rescan every state per layer" formulation.

  defp winning_region(domain, :strong) do
    index = edge_index(domain)

    pending =
      for {state, actions} <- domain.transitions,
          not MapSet.member?(domain.goals, state),
          {action, outcomes} <- actions,
          into: %{},
          do: {{state, action}, length(outcomes)}

    goals = domain.goals |> MapSet.to_list() |> Enum.sort()
    strong_layers(goals, index, pending, domain.goals, %{})
  end

  defp winning_region(domain, :strong_cyclic) do
    strong_cyclic_fixpoint(domain, edge_index(domain), domain.states)
  end

  # Backward attractor. A state joins layer `k + 1` with the smallest action
  # whose last non-winning outcome joined in layer `k`: that is the smallest
  # action with every outcome in layers `0..k`, because any action completed
  # earlier would have admitted the state in an earlier layer.
  defp strong_layers([], _index, _pending, winning, policy), do: {winning, policy}

  defp strong_layers(layer, index, pending, winning, policy) do
    {pending, completed} =
      Enum.reduce(layer, {pending, %{}}, fn outcome, acc ->
        index
        |> Map.get(outcome, [])
        |> Enum.reduce(acc, fn {state, action} = edge, {pending, completed} ->
          if MapSet.member?(winning, state) do
            {pending, completed}
          else
            remaining = Map.fetch!(pending, edge) - 1
            pending = Map.put(pending, edge, remaining)

            if remaining == 0,
              do: {pending, upsert_completed(completed, state, action)},
              else: {pending, completed}
          end
        end)
      end)

    chosen = Map.new(completed, fn {state, actions} -> {state, Enum.min(actions)} end)
    next_layer = chosen |> Map.keys() |> Enum.sort()
    winning = Enum.reduce(next_layer, winning, &MapSet.put(&2, &1))

    strong_layers(next_layer, index, pending, winning, Map.merge(policy, chosen))
  end

  # Greatest fixpoint: prune to states with a goal path through actions that
  # are closed in the current candidate set, until the set stops shrinking.
  defp upsert_completed(completed, state, action) do
    case Map.fetch(completed, state) do
      :error -> Map.put(completed, state, [action])
      {:ok, actions} -> Map.put(completed, state, [action | actions])
    end
  end

  defp strong_cyclic_fixpoint(domain, index, candidate) do
    {goal_reaching, policy} = goal_paths(domain, index, candidate)

    if MapSet.equal?(goal_reaching, candidate) do
      {candidate, policy}
    else
      strong_cyclic_fixpoint(domain, index, goal_reaching)
    end
  end

  # Layered backward weak reachability to the goals inside `candidate`, using
  # only candidate-closed actions. A state joins layer `k + 1` with the
  # smallest closed action that has an outcome in layer `k` (it cannot have
  # one in an earlier layer, or it would have joined earlier).
  defp goal_paths(domain, index, candidate) do
    goals = domain.goals |> MapSet.intersection(candidate) |> MapSet.to_list() |> Enum.sort()
    goal_layers(domain, index, candidate, goals, MapSet.new(goals), %{})
  end

  defp goal_layers(_domain, _index, _candidate, [], reached, policy), do: {reached, policy}

  defp goal_layers(domain, index, candidate, layer, reached, policy) do
    candidates =
      for outcome <- layer,
          {state, action} <- Map.get(index, outcome, []),
          MapSet.member?(candidate, state),
          not MapSet.member?(reached, state),
          all_outcomes_in?(domain, state, action, candidate),
          reduce: %{} do
        acc -> Map.update(acc, state, action, &min(&1, action))
      end

    next_layer = candidates |> Map.keys() |> Enum.sort()
    reached = Enum.reduce(next_layer, reached, &MapSet.put(&2, &1))

    goal_layers(domain, index, candidate, next_layer, reached, Map.merge(policy, candidates))
  end

  # outcome => [{state, action}] for every non-goal state; duplicate outcomes
  # were removed by `FOND.new/2`, so each edge appears once per outcome.
  defp edge_index(domain) do
    for {state, actions} <- domain.transitions,
        not MapSet.member?(domain.goals, state),
        {action, outcomes} <- actions,
        outcome <- outcomes,
        reduce: %{} do
      index -> case Map.fetch(index, outcome) do
        :error -> Map.put(index, outcome, [{state, action}])
        {:ok, pairs} -> Map.put(index, outcome, [{state, action} | pairs])
      end
    end
  end

  # -- policy extraction and witnesses ----------------------------------------

  defp restrict_to_reachable(domain, policy, initial) do
    walk(domain, [initial], MapSet.new(), %{}, fn state -> [Map.fetch!(policy, state)] end)
    |> Map.new(fn {state, [action]} -> {state, action} end)
  end

  # An unsolvable `initial` is never a goal (goals lie inside the winning set
  # in both modes), and `walk/5` records every visited non-goal state, so
  # `initial` is always among the keys. The court asserts `initial in witness`.
  defp witness_states(domain, winning, initial) do
    domain
    |> walk([initial], MapSet.new(), %{}, &FOND.actions(domain, &1))
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(winning, &1))
    |> Enum.sort()
  end

  # Depth-first walk that records, for every non-goal state visited, the
  # actions `choose` returns. Goal states are absorbing, as in validation.
  defp walk(_domain, [], _seen, acc, _choose), do: acc

  defp walk(domain, [state | rest], seen, acc, choose) do
    cond do
      MapSet.member?(seen, state) ->
        walk(domain, rest, seen, acc, choose)

      MapSet.member?(domain.goals, state) ->
        walk(domain, rest, MapSet.put(seen, state), acc, choose)

      true ->
        actions = choose.(state)
        successors = Enum.flat_map(actions, &FOND.outcomes(domain, state, &1))

        walk(
          domain,
          successors ++ rest,
          MapSet.put(seen, state),
          Map.put(acc, state, actions),
          choose
        )
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp all_outcomes_in?(domain, state, action, set) do
    case FOND.outcomes(domain, state, action) do
      [] -> false
      outcomes -> Enum.all?(outcomes, &MapSet.member?(set, &1))
    end
  end
end

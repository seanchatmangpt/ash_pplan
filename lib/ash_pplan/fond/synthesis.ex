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

  Refusals are typed:

    * `{:error, {:unsolvable, mode, witness_states}}` - no policy of the
      requested class exists from `initial`. `witness_states` is the sorted
      list of states reachable from `initial` under *any* action choice that
      lie outside the winning region. It always contains `initial`.
    * `{:error, {:unknown_initial_state, initial}}`
    * `{:error, {:invalid_mode, mode}}`
    * `{:error, {:invalid_domain, term}}`

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

  def synthesize(%FOND{}, _initial, mode), do: {:error, {:invalid_mode, mode}}
  def synthesize(domain, _initial, _mode), do: {:error, {:invalid_domain, domain}}

  @doc """
  Returns the sorted winning region for `mode`: every state from which a
  policy of that class exists (goal states included).
  """
  @spec solvable_states(FOND.t(), FOND.mode()) :: {:ok, [FOND.state()]} | {:error, refusal()}
  def solvable_states(%FOND{} = domain, mode) when mode in @modes do
    {winning, _policy} = winning_region(domain, mode)
    {:ok, winning |> MapSet.to_list() |> Enum.sort()}
  end

  def solvable_states(%FOND{}, mode), do: {:error, {:invalid_mode, mode}}
  def solvable_states(domain, _mode), do: {:error, {:invalid_domain, domain}}

  # -- winning regions -------------------------------------------------------

  defp winning_region(domain, :strong), do: strong_attractor(domain, domain.goals, %{})

  defp winning_region(domain, :strong_cyclic),
    do: strong_cyclic_fixpoint(domain, domain.states)

  # Backward attractor. Each layer is computed against the previous layer only,
  # so the recorded action strictly lowers the rank.
  defp strong_attractor(domain, winning, policy) do
    layer =
      domain
      |> sorted_non_goal_states(winning)
      |> Enum.flat_map(fn state ->
        case first_action(domain, state, &all_outcomes_in?(domain, state, &1, winning)) do
          nil -> []
          action -> [{state, action}]
        end
      end)

    case layer do
      [] ->
        {winning, policy}

      layer ->
        strong_attractor(
          domain,
          Enum.reduce(layer, winning, fn {state, _action}, acc -> MapSet.put(acc, state) end),
          Enum.into(layer, policy)
        )
    end
  end

  # Greatest fixpoint: prune to states with a goal path through actions that
  # are closed in the current candidate set, until the set stops shrinking.
  defp strong_cyclic_fixpoint(domain, candidate) do
    {goal_reaching, policy} =
      goal_paths(domain, candidate, MapSet.intersection(domain.goals, candidate), %{})

    if MapSet.equal?(goal_reaching, candidate) do
      {candidate, policy}
    else
      strong_cyclic_fixpoint(domain, goal_reaching)
    end
  end

  # Backward weak reachability to goals, restricted to candidate-closed actions.
  defp goal_paths(domain, candidate, reached, policy) do
    layer =
      domain
      |> sorted_non_goal_states(reached)
      |> Enum.filter(&MapSet.member?(candidate, &1))
      |> Enum.flat_map(fn state ->
        admitted? = fn action ->
          all_outcomes_in?(domain, state, action, candidate) and
            any_outcome_in?(domain, state, action, reached)
        end

        case first_action(domain, state, admitted?) do
          nil -> []
          action -> [{state, action}]
        end
      end)

    case layer do
      [] ->
        {reached, policy}

      layer ->
        goal_paths(
          domain,
          candidate,
          Enum.reduce(layer, reached, fn {state, _action}, acc -> MapSet.put(acc, state) end),
          Enum.into(layer, policy)
        )
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

  defp sorted_non_goal_states(domain, excluded) do
    domain.states
    |> MapSet.difference(excluded)
    |> MapSet.difference(domain.goals)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp first_action(domain, state, admitted?) do
    domain
    |> FOND.actions(state)
    |> Enum.find(admitted?)
  end

  defp all_outcomes_in?(domain, state, action, set),
    do: Enum.all?(FOND.outcomes(domain, state, action), &MapSet.member?(set, &1))

  defp any_outcome_in?(domain, state, action, set),
    do: Enum.any?(FOND.outcomes(domain, state, action), &MapSet.member?(set, &1))
end

defmodule AshPPlan.FOND do
  @moduledoc """
  Finite, fully observable nondeterministic policy semantics for `ash_pplan`.

  Reactor remains the executor. This module models the policy layer Reactor does
  not own: for a symbolic state and selected action, which successor states may
  the environment produce, and does a candidate policy reach a goal under
  strong or strong-cyclic semantics?

  A domain is pure data. `transitions` has the form:

      %{
        pending: %{attempt: [:pending, :succeeded]},
        succeeded: %{}
      }

  A policy maps every reachable non-goal state to one admitted action:

      %{pending: :attempt}

  `:strong` requires all executions to reach a goal without relying on fairness.
  `:strong_cyclic` permits retry cycles when every reachable policy state still
  has a path to a goal; this is the standard fairness assumption used for
  strong-cyclic FOND policies.
  """

  @enforce_keys [:states, :goals, :transitions]
  defstruct [:states, :goals, :transitions]

  @type state :: term()
  @type action :: term()
  @type policy :: %{optional(state()) => action()}
  @type t :: %__MODULE__{
          states: MapSet.t(state()),
          goals: MapSet.t(state()),
          transitions: %{optional(state()) => %{optional(action()) => [state()]}}
        }

  @doc "Builds a normalized FOND domain from a transition relation and goal states."
  @spec new(map(), term()) :: {:ok, t()} | {:error, map()}
  def new(transitions, goals \\ []) when is_map(transitions) do
    with {:ok, transitions} <- normalize_transitions(transitions) do
      goals = MapSet.new(goals)
      states = collect_states(transitions, goals)

      {:ok, %__MODULE__{states: states, goals: goals, transitions: transitions}}
    end
  end

  def new(transitions, _goals),
    do: {:error, %{reason: :invalid_transition_relation, transitions: transitions}}

  @doc "Returns admitted actions for a state."
  @spec actions(t(), state()) :: [action()]
  def actions(%__MODULE__{transitions: transitions}, state) do
    transitions
    |> Map.get(state, %{})
    |> Map.keys()
    |> Enum.sort()
  end

  @doc "Returns all nondeterministic outcomes admitted for `state × action`."
  @spec outcomes(t(), state(), action()) :: [state()]
  def outcomes(%__MODULE__{transitions: transitions}, state, action) do
    transitions
    |> Map.get(state, %{})
    |> Map.get(action, [])
  end

  @doc """
  Validates a candidate policy from one initial state.

  Returns a receipt-like report containing the complete reachable policy state
  set when the candidate satisfies the requested semantics. It refuses missing
  policy decisions, unavailable actions, and policies that cannot establish the
  requested goal guarantee.
  """
  @spec validate_policy(t(), policy(), state(), :strong | :strong_cyclic) ::
          {:ok, map()} | {:error, map()}
  def validate_policy(%__MODULE__{} = domain, policy, initial, mode \\ :strong_cyclic)
      when is_map(policy) and mode in [:strong, :strong_cyclic] do
    if MapSet.member?(domain.states, initial) do
      with {:ok, reachable} <- reachable_under_policy(domain, policy, initial) do
        validate_mode(domain, policy, initial, reachable, mode)
      end
    else
      {:error, %{reason: :unknown_initial_state, state: initial}}
    end
  end

  def validate_policy(_domain, policy, initial, mode),
    do: {:error, %{reason: :invalid_policy_request, policy: policy, initial: initial, mode: mode}}

  defp normalize_transitions(transitions) do
    Enum.reduce_while(transitions, {:ok, %{}}, fn {state, actions}, {:ok, acc} ->
      if is_map(actions) do
        case normalize_actions(state, actions) do
          {:ok, actions} -> {:cont, {:ok, Map.put(acc, state, actions)}}
          {:error, error} -> {:halt, {:error, error}}
        end
      else
        {:halt, {:error, %{reason: :invalid_actions, state: state, actions: actions}}}
      end
    end)
  end

  defp normalize_actions(state, actions) do
    Enum.reduce_while(actions, {:ok, %{}}, fn {action, outcomes}, {:ok, acc} ->
      case normalize_outcomes(outcomes) do
        {:ok, []} ->
          {:halt,
           {:error, %{reason: :empty_nondeterministic_outcome, state: state, action: action}}}

        {:ok, outcomes} ->
          {:cont, {:ok, Map.put(acc, action, outcomes)}}

        :error ->
          {:halt,
           {:error, %{reason: :invalid_nondeterministic_outcomes, state: state, action: action}}}
      end
    end)
  end

  defp normalize_outcomes(%MapSet{} = outcomes),
    do: {:ok, outcomes |> MapSet.to_list() |> Enum.uniq() |> Enum.sort()}

  defp normalize_outcomes(outcomes) when is_list(outcomes),
    do: {:ok, outcomes |> Enum.uniq() |> Enum.sort()}

  defp normalize_outcomes(_outcomes), do: :error

  defp collect_states(transitions, goals) do
    Enum.reduce(transitions, goals, fn {state, actions}, states ->
      states = MapSet.put(states, state)

      Enum.reduce(actions, states, fn {_action, outcomes}, states ->
        Enum.reduce(outcomes, states, &MapSet.put(&2, &1))
      end)
    end)
  end

  defp reachable_under_policy(domain, policy, initial) do
    walk_reachable(domain, policy, [initial], MapSet.new())
  end

  defp walk_reachable(_domain, _policy, [], seen), do: {:ok, seen}

  defp walk_reachable(domain, policy, [state | rest], seen) do
    if MapSet.member?(seen, state) do
      walk_reachable(domain, policy, rest, seen)
    else
      seen = MapSet.put(seen, state)

      if MapSet.member?(domain.goals, state) do
        walk_reachable(domain, policy, rest, seen)
      else
        with {:ok, action} <- fetch_policy_action(policy, state),
             {:ok, outcomes} <- fetch_action_outcomes(domain, state, action) do
          walk_reachable(domain, policy, rest ++ outcomes, seen)
        end
      end
    end
  end

  defp fetch_policy_action(policy, state) do
    case Map.fetch(policy, state) do
      {:ok, action} -> {:ok, action}
      :error -> {:error, %{reason: :missing_policy_action, state: state}}
    end
  end

  defp fetch_action_outcomes(domain, state, action) do
    case outcomes(domain, state, action) do
      [] ->
        {:error,
         %{
           reason: :unavailable_policy_action,
           state: state,
           action: action,
           available: actions(domain, state)
         }}

      outcomes ->
        {:ok, outcomes}
    end
  end

  defp validate_mode(domain, policy, initial, reachable, :strong) do
    winning =
      strong_fixed_point(domain, policy, reachable, MapSet.intersection(domain.goals, reachable))

    if MapSet.subset?(reachable, winning) do
      {:ok, policy_report(initial, reachable, :strong)}
    else
      {:error,
       %{
         reason: :not_strong,
         initial: initial,
         losing_states: difference_sorted(reachable, winning)
       }}
    end
  end

  defp validate_mode(domain, policy, initial, reachable, :strong_cyclic) do
    goal_reachable =
      strong_cyclic_fixed_point(
        domain,
        policy,
        reachable,
        MapSet.intersection(domain.goals, reachable)
      )

    if MapSet.subset?(reachable, goal_reachable) do
      {:ok, policy_report(initial, reachable, :strong_cyclic)}
    else
      {:error,
       %{
         reason: :not_strong_cyclic,
         initial: initial,
         states_without_goal_path: difference_sorted(reachable, goal_reachable)
       }}
    end
  end

  defp strong_fixed_point(domain, policy, reachable, winning) do
    next =
      Enum.reduce(reachable, winning, fn state, acc ->
        cond do
          MapSet.member?(acc, state) ->
            acc

          MapSet.member?(domain.goals, state) ->
            MapSet.put(acc, state)

          true ->
            action = Map.fetch!(policy, state)
            successors = outcomes(domain, state, action)

            if successors != [] and Enum.all?(successors, &MapSet.member?(acc, &1)) do
              MapSet.put(acc, state)
            else
              acc
            end
        end
      end)

    if MapSet.equal?(next, winning),
      do: winning,
      else: strong_fixed_point(domain, policy, reachable, next)
  end

  defp strong_cyclic_fixed_point(domain, policy, reachable, can_reach_goal) do
    next =
      Enum.reduce(reachable, can_reach_goal, fn state, acc ->
        cond do
          MapSet.member?(acc, state) ->
            acc

          MapSet.member?(domain.goals, state) ->
            MapSet.put(acc, state)

          true ->
            action = Map.fetch!(policy, state)
            successors = outcomes(domain, state, action)

            if Enum.any?(successors, &MapSet.member?(acc, &1)) do
              MapSet.put(acc, state)
            else
              acc
            end
        end
      end)

    if MapSet.equal?(next, can_reach_goal),
      do: can_reach_goal,
      else: strong_cyclic_fixed_point(domain, policy, reachable, next)
  end

  defp policy_report(initial, reachable, mode) do
    %{
      semantics: mode,
      initial: initial,
      reachable_states: reachable |> MapSet.to_list() |> Enum.sort(),
      reachable_count: MapSet.size(reachable)
    }
  end

  defp difference_sorted(left, right) do
    left
    |> MapSet.difference(right)
    |> MapSet.to_list()
    |> Enum.sort()
  end
end

defmodule AshPPlan.FOND.Trace do
  @moduledoc """
  Bounded graph traces for a FOND policy.

  Traces are constructed from the explicit transition relation and are useful
  for counterexample explanation and replay fixtures. They do not execute a
  policy.
  """

  alias AshPPlan.FOND

  @spec edges(FOND.t(), FOND.policy()) :: [map()]
  def edges(%FOND{} = domain, policy) when is_map(policy) do
    policy
    |> Enum.sort()
    |> Enum.flat_map(fn {state, action} ->
      domain
      |> FOND.outcomes(state, action)
      |> Enum.with_index()
      |> Enum.map(fn {outcome, index} ->
        %{from: state, action: action, outcome_index: index, to: outcome}
      end)
    end)
  end

  @spec shortest_goal_path(FOND.t(), FOND.policy(), FOND.state()) ::
          {:ok, [FOND.state()]} | {:error, map()}
  def shortest_goal_path(%FOND{} = domain, policy, initial) when is_map(policy) do
    cond do
      not MapSet.member?(domain.states, initial) ->
        {:error, %{reason: :unknown_initial_state, state: initial}}

      MapSet.member?(domain.goals, initial) ->
        {:ok, [initial]}

      true ->
        bfs(domain, policy, [{initial, [initial]}], MapSet.new())
    end
  end

  defp bfs(_domain, _policy, [], _seen),
    do: {:error, %{reason: :no_goal_path}}

  defp bfs(domain, policy, [{state, path} | rest], seen) do
    if MapSet.member?(seen, state) do
      bfs(domain, policy, rest, seen)
    else
      seen = MapSet.put(seen, state)

      with {:ok, action} <- Map.fetch(policy, state) do
        next =
          domain
          |> FOND.outcomes(state, action)
          |> Enum.sort()
          |> Enum.map(&{&1, path ++ [&1]})

        case Enum.find(next, fn {candidate, _} -> MapSet.member?(domain.goals, candidate) end) do
          {_goal, goal_path} -> {:ok, goal_path}
          nil -> bfs(domain, policy, rest ++ next, seen)
        end
      else
        :error -> {:error, %{reason: :missing_policy_action, state: state}}
      end
    end
  end
end

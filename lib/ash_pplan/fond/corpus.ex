defmodule AshPPlan.FOND.Corpus do
  @moduledoc """
  Seeded finite FOND corpus generator for replayable differential campaigns.

  It intentionally produces valid domains with policies that may be incomplete
  or unavailable so refusal paths are represented alongside admitted policies.
  """

  @spec seeded(pos_integer(), {integer(), integer(), integer()}) :: [map()]
  def seeded(count, seed \\ {11, 29, 47}) when is_integer(count) and count > 0 do
    rand = :rand.seed_s(:exsss, seed)

    {cases, _rand} =
      Enum.map_reduce(1..count, rand, fn index, state ->
        generate_case(index, state)
      end)

    cases
  end

  defp generate_case(index, rand) do
    {n, rand} = uniform(rand, 5)
    states = for i <- 0..n, do: :"s#{index}_#{i}"
    {goal, rand} = pick(rand, states)
    goals = [goal]

    {transitions, rand} =
      Enum.map_reduce(states, rand, fn state, rand ->
        if state == goal do
          {{state, %{}}, rand}
        else
          {outcome_count, rand} = uniform(rand, min(3, length(states)))
          {outcomes, rand} = picks(rand, states, outcome_count)
          {{state, %{advance: Enum.uniq(outcomes)}}, rand}
        end
      end)

    transitions = Map.new(transitions)

    {policy, rand} =
      Enum.reduce(states, {%{}, rand}, fn state, {policy, rand} ->
        cond do
          state == goal ->
            {policy, rand}

          true ->
            {roll, rand} = uniform(rand, 10)

            cond do
              roll == 1 -> {policy, rand}
              roll == 2 -> {Map.put(policy, state, :invented), rand}
              true -> {Map.put(policy, state, :advance), rand}
            end
        end
      end)

    {initial, rand} = pick(rand, states)

    {%{
       id: "seeded-#{index}",
       transitions: transitions,
       goals: goals,
       policy: policy,
       initial: initial
     }, rand}
  end

  defp picks(rand, list, count) do
    Enum.map_reduce(1..count, rand, fn _, rand -> pick(rand, list) end)
  end

  defp pick(rand, list) do
    {i, rand} = uniform(rand, length(list))
    {Enum.at(list, i - 1), rand}
  end

  defp uniform(rand, n), do: :rand.uniform_s(n, rand)
end

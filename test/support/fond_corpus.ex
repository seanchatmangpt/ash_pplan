defmodule AshPPlan.Test.FONDCorpus do
  @moduledoc """
  Shared FOND x TLA+ court corpus and a seeded generator of small random
  domains.

  `cases/0` is the hand-written corpus (name => {transitions, goals, policy,
  initial, expected %{strong:, strong_cyclic:}}). `random/2` produces
  `{transitions, goals, policy, initial}` tuples from an explicit `:rand` seed so
  every run of the differential courts examines the same domains (replayable),
  including policies with missing decisions and invented actions.
  """

  def cases do
    [
      retry_cycle:
        {%{pending: %{attempt: [:pending, :succeeded]}, succeeded: %{}}, [:succeeded],
         %{pending: :attempt}, :pending, %{strong: :refused, strong_cyclic: :admitted}},
      two_state_retry:
        {%{
           s0: %{try: [:s0, :s1]},
           s1: %{try: [:s0, :done]},
           done: %{}
         }, [:done], %{s0: :try, s1: :try}, :s0, %{strong: :refused, strong_cyclic: :admitted}},
      pure_strong_fanout:
        {%{pending: %{finish: [:succeeded, :failed]}, succeeded: %{}, failed: %{}},
         [:succeeded, :failed], %{pending: :finish}, :pending,
         %{strong: :admitted, strong_cyclic: :admitted}},
      pure_strong_chain:
        {%{
           a: %{go: [:b, :c]},
           b: %{go: [:c]},
           c: %{go: [:goal_1, :goal_2]},
           goal_1: %{},
           goal_2: %{}
         }, [:goal_1, :goal_2], %{a: :go, b: :go, c: :go}, :a,
         %{strong: :admitted, strong_cyclic: :admitted}},
      dead_end:
        {%{pending: %{finish: [:succeeded, :failed]}, succeeded: %{}, failed: %{}}, [:succeeded],
         %{pending: :finish}, :pending, %{strong: :refused, strong_cyclic: :refused}},
      retry_into_dead_end:
        {%{pending: %{attempt: [:pending, :broken]}, broken: %{}, succeeded: %{}}, [:succeeded],
         %{pending: :attempt}, :pending, %{strong: :refused, strong_cyclic: :refused}},
      missing_decision:
        {%{
           pending: %{attempt: [:review]},
           review: %{approve: [:succeeded]},
           succeeded: %{}
         }, [:succeeded], %{pending: :attempt}, :pending,
         %{strong: :refused, strong_cyclic: :refused}},
      unavailable_action:
        {%{pending: %{attempt: [:succeeded]}, succeeded: %{}}, [:succeeded],
         %{pending: :invented}, :pending, %{strong: :refused, strong_cyclic: :refused}},
      closed_trap:
        {%{pending: %{attempt: [:stuck]}, stuck: %{retry: [:stuck]}, succeeded: %{}},
         [:succeeded], %{pending: :attempt, stuck: :retry}, :pending,
         %{strong: :refused, strong_cyclic: :refused}},
      branch_into_trap:
        {%{
           pending: %{attempt: [:succeeded, :trap]},
           trap: %{spin: [:trap_b]},
           trap_b: %{spin: [:trap]},
           succeeded: %{}
         }, [:succeeded], %{pending: :attempt, trap: :spin, trap_b: :spin}, :pending,
         %{strong: :refused, strong_cyclic: :refused}},
      initial_is_goal:
        {%{done: %{}}, [:done], %{}, :done, %{strong: :admitted, strong_cyclic: :admitted}},
      unreachable_undecided_state:
        {%{
           pending: %{attempt: [:succeeded]},
           orphan: %{attempt: [:orphan]},
           succeeded: %{}
         }, [:succeeded], %{pending: :attempt}, :pending,
         %{strong: :admitted, strong_cyclic: :admitted}},
      decision_choice_matters:
        {%{
           pending: %{safe: [:succeeded], risky: [:pending, :succeeded]},
           succeeded: %{}
         }, [:succeeded], %{pending: :risky}, :pending,
         %{strong: :refused, strong_cyclic: :admitted}}
    ]
  end

  @doc "Deterministic list of `count` random `{transitions, goals, policy, initial}`."
  def random(count, seed \\ {1, 2, 3}) do
    state = :rand.seed_s(:exsss, seed)

    {cases, _state} =
      Enum.map_reduce(1..count, state, fn _i, st -> random_case(st) end)

    cases
  end

  defp random_case(st) do
    {n, st} = uniform(st, 6)
    n = n + 1
    states = Enum.map(1..n, &:"q#{&1}")

    {transitions, st} =
      Enum.map_reduce(states, st, fn s, st ->
        {k, st} = uniform(st, 3)

        {actions, st} =
          Enum.map_reduce(1..(k - 1)//1, st, fn j, st ->
            {m, st} = uniform(st, 3)
            {outs, st} = Enum.map_reduce(1..m, st, fn _o, st -> pick(st, states) end)
            {{:"a#{j}", outs}, st}
          end)

        {{s, Map.new(actions)}, st}
      end)

    transitions = Map.new(transitions)

    {goal_count, st} = uniform(st, 3)
    {goals, st} = Enum.map_reduce(1..(goal_count - 1)//1, st, fn _g, st -> pick(st, states) end)

    {policy, st} =
      Enum.flat_map_reduce(states, st, fn s, st ->
        actions = transitions |> Map.fetch!(s) |> Map.keys() |> Enum.sort()
        {roll, st} = uniform(st, 10)

        cond do
          roll == 1 -> {[], st}
          roll == 2 -> {[{s, :invented}], st}
          actions == [] -> {[], st}
          true -> pick(st, actions) |> then(fn {a, st} -> {[{s, a}], st} end)
        end
      end)

    {initial, st} = pick(st, states)
    {{transitions, Enum.uniq(goals), Map.new(policy), initial}, st}
  end

  defp uniform(st, n) do
    {x, st} = :rand.uniform_s(n, st)
    {x, st}
  end

  defp pick(st, list) do
    {i, st} = uniform(st, length(list))
    {Enum.at(list, i - 1), st}
  end
end

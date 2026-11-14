defmodule AshPPlan.FONDSynthesisPm4Test do
  @moduledoc """
  Process-conformance validation of the FOND lane: every event is derived from
  a real `AshPPlan.FOND` / `Synthesis` / `Trace` call result.

  The model (valid paths) is enumerated from the synthesized policy and
  `FOND.outcomes/3`; executed traces are rollouts of that same policy under
  seeded outcome resolution (strong-cyclic fairness: after `@max_free_visits`
  visits to a state the environment takes the goal-ward outcome).
  """
  use ExUnit.Case, async: true
  use Pm4ExUnit

  alias AshPPlan.FOND
  alias AshPPlan.FOND.{Synthesis, Trace}

  @moduletag :pm4exunit

  @max_free_visits 1
  @initial :pending

  defp domain! do
    {:ok, domain} =
      FOND.new(
        %{
          pending: %{attempt: [:pending, :running]},
          running: %{finish: [:done, :failed]},
          failed: %{recover: [:pending]},
          done: %{},
          orphan: %{salvage: [:done]}
        },
        [:done]
      )

    domain
  end

  defp policy! do
    {:ok, policy} = Synthesis.synthesize(domain!(), @initial, :strong_cyclic)
    policy
  end

  # pm4 token replay cannot match a path that repeats an activity label, so each step carries the
  # visit ordinal of its source state ("pending.attempt->running#1" = second time at pending).
  defp activity(from, action, to, n \\ 0), do: "#{from}.#{action}->#{to}##{n}"

  defp labels(steps) do
    {labels, _} =
      Enum.map_reduce(steps, %{}, fn {f, a, t}, seen ->
        n = Map.get(seen, f, 0)
        {activity(f, a, t, n), Map.put(seen, f, n + 1)}
      end)

    labels
  end

  # Outcomes the environment may produce at `state`, given prior visit count.
  defp allowed_outcomes(domain, policy, state, visits) do
    action = Map.fetch!(policy, state)
    outcomes = FOND.outcomes(domain, state, action)

    if Map.get(visits, state, 0) >= @max_free_visits do
      {:ok, [^state, next | _]} = Trace.shortest_goal_path(domain, policy, state)
      {action, [next]}
    else
      {action, outcomes}
    end
  end

  # All model paths (list of activity strings), derived from policy + outcomes.
  defp model_paths(domain, policy, state, visits \\ %{}, acc \\ []) do
    if MapSet.member?(domain.goals, state) do
      [Enum.reverse(acc)]
    else
      {action, outs} = allowed_outcomes(domain, policy, state, visits)
      visits = Map.update(visits, state, 1, &(&1 + 1))

      Enum.flat_map(outs, fn to ->
        model_paths(domain, policy, to, visits, [
          activity(state, action, to, Map.get(visits, state, 1) - 1) | acc
        ])
      end)
    end
  end

  # Seeded rollout: returns [{from, action, to}].
  defp rollout(domain, policy, initial, seed) do
    rand = :rand.seed_s(:exsss, {seed, seed + 7, seed + 13})
    do_rollout(domain, policy, initial, rand, %{}, [])
  end

  defp do_rollout(domain, policy, state, rand, visits, acc) do
    if MapSet.member?(domain.goals, state) do
      Enum.reverse(acc)
    else
      {action, outs} = allowed_outcomes(domain, policy, state, visits)
      {i, rand} = :rand.uniform_s(length(outs), rand)
      to = Enum.at(outs, i - 1)
      visits = Map.update(visits, state, 1, &(&1 + 1))
      do_rollout(domain, policy, to, rand, visits, [{state, action, to} | acc])
    end
  end

  defp emit_steps(session, prefix, steps) do
    steps
    |> labels()
    |> Enum.with_index()
    |> Enum.each(fn {label, i} -> emit_event(session, "#{prefix}-#{i}", label) end)
  end

  defp fresh_session(name) do
    {:ok, session} = Pm4ExUnit.Session.start_link(test_name: name)
    session
  end

  # Steps along the shortest goal path, actions taken from the policy and
  # targets confirmed against FOND.outcomes/3.
  defp canonical_steps(domain, policy) do
    {:ok, path} = Trace.shortest_goal_path(domain, policy, @initial)

    path
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [from, to] ->
      action = Map.fetch!(policy, from)
      assert to in FOND.outcomes(domain, from, action)
      {from, action, to}
    end)
  end

  describe "synthesis lifecycle" do
    test "synthesize -> validate -> goal path follows the lifecycle model",
         %{pm4_session: session} do
      domain = domain!()

      assert {:ok, policy} = Synthesis.synthesize(domain, @initial, :strong_cyclic)
      emit_event(session, "l1", :synthesized)

      assert {:ok, %{semantics: :strong_cyclic}} =
               FOND.validate_policy(domain, policy, @initial, :strong_cyclic)

      emit_event(session, "l2", :validated)

      assert {:ok, path} = Trace.shortest_goal_path(domain, policy, @initial)
      assert MapSet.member?(domain.goals, List.last(path))
      emit_event(session, "l3", :goal_reached)

      assert_conformance(session, [[:synthesized, :validated, :goal_reached]])
    end

    test "a policy validation refusal deviates from the lifecycle model",
         %{pm4_session: session} do
      domain = domain!()
      policy = policy!()
      emit_event(session, "l1", :synthesized)

      bad = Map.put(policy, :running, :invented)

      assert {:error, %{reason: :unavailable_policy_action, action: :invented}} =
               FOND.validate_policy(domain, bad, @initial, :strong_cyclic)

      emit_event(session, "l2", :validation_refused)

      refute_conformance(session, [[:synthesized, :validated, :goal_reached]])
    end

    test "strong mode is refused on the retry-cycle fixture with typed witnesses" do
      assert {:error, {:unsolvable, :strong, witnesses}} =
               Synthesis.synthesize(domain!(), @initial, :strong)

      assert @initial in witnesses
    end

    test "synthesized policy reaches only domain states and excludes the orphan" do
      domain = domain!()
      policy = policy!()

      assert {:ok, report} = FOND.validate_policy(domain, policy, @initial, :strong_cyclic)
      refute :orphan in report.reachable_states
      assert :done in report.reachable_states
    end
  end

  describe "executed traces conform to the policy path model" do
    test "shortest goal path (Trace) is a model path", %{pm4_session: session} do
      domain = domain!()
      policy = policy!()

      steps = canonical_steps(domain, policy)
      emit_steps(session, "c", steps)

      assert_conformance(session, model_paths(domain, policy, @initial))
    end

    test "a seeded rollout ends in a goal and conforms", %{pm4_session: session} do
      domain = domain!()
      policy = policy!()

      steps = rollout(domain, policy, @initial, 1)
      {_from, _action, last} = List.last(steps)
      assert MapSet.member?(domain.goals, last)

      for {from, action, to} <- steps do
        assert action == Map.fetch!(policy, from)
        assert to in FOND.outcomes(domain, from, action)
      end

      emit_steps(session, "r", steps)
      assert_conformance(session, model_paths(domain, policy, @initial))
    end

    test "conformance holds across many seeded outcome resolutions" do
      domain = domain!()
      policy = policy!()
      model = model_paths(domain, policy, @initial)

      traces =
        for seed <- 1..24 do
          session = fresh_session("fond-seed-#{seed}")
          steps = rollout(domain, policy, @initial, seed)
          emit_steps(session, "s#{seed}", steps)

          result = assert_conformance(session, model)
          assert result.fitness == 1.0

          labels(steps)
        end

      assert length(Enum.uniq(traces)) >= 2
    end

    test "every model path is itself accepted and reaches the goal" do
      domain = domain!()
      policy = policy!()
      model = model_paths(domain, policy, @initial)
      assert model != []

      for {path, i} <- Enum.with_index(model) do
        session = fresh_session("fond-model-#{i}")

        path
        |> Enum.with_index()
        |> Enum.each(fn {act, j} -> emit_event(session, "m#{i}-#{j}", act) end)

        assert_conformance(session, model)
        assert List.last(path) |> String.contains?("->done#")
      end
    end
  end

  describe "violating traces are refuted" do
    test "action applied in a state unreachable under the policy", %{pm4_session: session} do
      domain = domain!()
      policy = policy!()

      assert [:done] = FOND.outcomes(domain, :orphan, :salvage)
      refute Map.has_key?(policy, :orphan)

      emit_event(session, "o1", activity(:orphan, :salvage, :done))

      refute_conformance(session, model_paths(domain, policy, @initial))
    end

    test "unreachable-state step spliced into an otherwise valid trace", %{pm4_session: session} do
      domain = domain!()
      policy = policy!()

      [_first | rest] = canonical_steps(domain, policy)
      emit_event(session, "x0", activity(:orphan, :salvage, :done))
      emit_steps(session, "x", rest)

      refute_conformance(session, model_paths(domain, policy, @initial))
    end

    test "action before its precondition (steps out of order)", %{pm4_session: session} do
      domain = domain!()
      policy = policy!()

      steps = domain |> canonical_steps(policy) |> Enum.reverse()
      assert length(steps) >= 2
      emit_steps(session, "p", steps)

      refute_conformance(session, model_paths(domain, policy, @initial))
    end

    test "trace that stops before the goal", %{pm4_session: session} do
      domain = domain!()
      policy = policy!()

      steps = domain |> canonical_steps(policy) |> Enum.drop(-1)
      emit_steps(session, "t", steps)

      refute_conformance(session, model_paths(domain, policy, @initial))
    end
  end
end

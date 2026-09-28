defmodule AshPPlan.FONDHardeningTest do
  @moduledoc """
  Fail-closed admission, determinism and scaling falsifiers for
  `AshPPlan.FOND` and `AshPPlan.FOND.Synthesis`.

  Every assertion runs the real validator and synthesizer over real domains;
  nothing is stubbed.
  """

  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.FOND.Synthesis

  @modes [:strong, :strong_cyclic]

  describe "domain admission" do
    test "goals must be a list or a MapSet" do
      for goals <- [:succeeded, "succeeded", nil, %{succeeded: true}] do
        assert {:error, %{reason: :invalid_goals, goals: ^goals}} =
                 FOND.new(%{pending: %{attempt: [:succeeded]}}, goals)
      end

      assert {:ok, %FOND{goals: goals}} =
               FOND.new(%{pending: %{attempt: [:succeeded]}}, MapSet.new([:succeeded]))

      assert goals == MapSet.new([:succeeded])
    end

    test "non-map actions and non-list outcomes are refused" do
      assert {:error, %{reason: :invalid_actions, state: :pending}} =
               FOND.new(%{pending: [:attempt]})

      assert {:error, %{reason: :invalid_nondeterministic_outcomes, action: :attempt}} =
               FOND.new(%{pending: %{attempt: :succeeded}})
    end

    test "outcomes normalize independently of how numerically-equal terms were spelled" do
      {:ok, left} = FOND.new(%{s: %{a: [1, 1.0]}})
      {:ok, right} = FOND.new(%{s: %{a: [1.0, 1]}})

      assert left == right
    end

    test "a hand-built domain with an empty outcome list is refused, not vacuously solved" do
      domain = %FOND{
        states: MapSet.new([:a, :g]),
        goals: MapSet.new([:g]),
        transitions: %{a: %{noop: []}}
      }

      assert {:error, %{reason: :invalid_domain, detail: :unnormalized_transitions}} =
               FOND.check(domain)

      for mode <- @modes do
        assert {:error, {:invalid_domain, %{reason: :invalid_domain}}} =
                 Synthesis.synthesize(domain, :a, mode)

        assert {:error, {:invalid_domain, _}} = Synthesis.solvable_states(domain, mode)

        assert {:error, %{reason: :invalid_domain}} =
                 FOND.validate_policy(domain, %{a: :noop}, :a, mode)
      end
    end

    test "a hand-built domain whose relation names undeclared states is refused" do
      domain = %FOND{
        states: MapSet.new([:a]),
        goals: MapSet.new([:g]),
        transitions: %{a: %{go: [:g]}}
      }

      assert {:error, %{reason: :invalid_domain, detail: :undeclared_states, states: [:g]}} =
               FOND.check(domain)
    end

    test "anything that is not a FOND struct is refused" do
      assert {:error, %{reason: :invalid_domain, detail: :not_a_fond_domain}} = FOND.check(%{})
    end
  end

  describe "policy admission" do
    setup do
      {:ok, domain} =
        FOND.new(
          %{
            pending: %{attempt: [:pending, :succeeded]},
            side: %{wander: [:pending]}
          },
          [:succeeded]
        )

      %{domain: domain}
    end

    test "entries for states outside the domain are refused", %{domain: domain} do
      assert {:error, %{reason: :unknown_policy_states, states: [:nowhere]}} =
               FOND.validate_policy(domain, %{pending: :attempt, nowhere: :fly}, :pending)
    end

    test "an unavailable action is refused where the policy is followed", %{domain: domain} do
      assert {:error,
              %{
                reason: :unavailable_policy_action,
                state: :pending,
                action: :teleport,
                available: [:attempt]
              }} =
               FOND.validate_policy(domain, %{pending: :teleport}, :pending)
    end

    test "an unavailable action on an unreachable state cannot change a verdict", %{
      domain: domain
    } do
      # Agrees with the TLC and independent-reader courts: only reachable
      # behaviour decides the verdict, and the stray entry is reported.
      assert {:ok, %{ignored_policy_states: [:side]}} =
               FOND.validate_policy(domain, %{pending: :attempt, side: :teleport}, :pending)
    end

    test "unreachable and goal entries are reported, not silently approved", %{domain: domain} do
      assert {:ok, %{ignored_policy_states: [:side]}} =
               FOND.validate_policy(domain, %{pending: :attempt, side: :wander}, :pending)

      assert {:ok, %{ignored_policy_states: []}} =
               FOND.validate_policy(domain, %{pending: :attempt}, :pending)
    end

    test "string keys do not satisfy an atom-keyed domain", %{domain: domain} do
      assert {:error, %{reason: :unknown_policy_states, states: ["pending"]}} =
               FOND.validate_policy(domain, %{"pending" => :attempt}, :pending)
    end

    test "the default mode is strong-cyclic", %{domain: domain} do
      assert {:ok, %{semantics: :strong_cyclic}} =
               FOND.validate_policy(domain, %{pending: :attempt}, :pending)
    end

    test "malformed requests are refused", %{domain: domain} do
      assert {:error, %{reason: :invalid_policy_request}} =
               FOND.validate_policy(domain, %{pending: :attempt}, :pending, :weak)

      assert {:error, %{reason: :invalid_policy_request}} =
               FOND.validate_policy(domain, [pending: :attempt], :pending)
    end

    test "a self-loop with a goal exit is strong-cyclic but not strong" do
      {:ok, domain} = FOND.new(%{s: %{a: [:s, :g]}}, [:g])

      assert {:error, %{reason: :not_strong, losing_states: [:s]}} =
               FOND.validate_policy(domain, %{s: :a}, :s, :strong)

      assert {:ok, %{reachable_states: [:g, :s]}} =
               FOND.validate_policy(domain, %{s: :a}, :s, :strong_cyclic)
    end

    test "losing and goal-less state payloads name exactly the offending states" do
      {:ok, domain} =
        FOND.new(%{a: %{go: [:b, :trap]}, b: %{go: [:g]}, trap: %{spin: [:trap]}}, [:g])

      policy = %{a: :go, b: :go, trap: :spin}

      assert {:error, %{reason: :not_strong, losing_states: [:a, :trap]}} =
               FOND.validate_policy(domain, policy, :a, :strong)

      assert {:error, %{reason: :not_strong_cyclic, states_without_goal_path: [:trap]}} =
               FOND.validate_policy(domain, policy, :a, :strong_cyclic)
    end
  end

  describe "synthesis is the naive layered fixpoint, computed faster" do
    # The worklist implementation must choose exactly the actions the textbook
    # "rescan every state per layer" formulation chooses. This reference is
    # that formulation, kept deliberately naive.
    test "random domains: identical winning regions and identical policies" do
      :rand.seed(:exsss, {26, 9, 28})

      for _ <- 1..300, mode <- @modes do
        domain = random_domain(Enum.random(1..9), [:a, :b, :c])
        {:ok, solvable} = Synthesis.solvable_states(domain, mode)
        {reference_winning, reference_policy} = reference_region(domain, mode)

        assert solvable == reference_winning |> MapSet.to_list() |> Enum.sort()

        for initial <- solvable, not MapSet.member?(domain.goals, initial) do
          assert {:ok, policy} = Synthesis.synthesize(domain, initial, mode)
          assert Enum.all?(policy, fn {state, action} -> reference_policy[state] == action end)
          assert {:ok, _} = FOND.validate_policy(domain, policy, initial, mode)
        end
      end
    end

    test "unsolvable witnesses contain the initial state and avoid the winning region" do
      :rand.seed(:exsss, {9, 28, 26})

      for _ <- 1..200, mode <- @modes do
        domain = random_domain(Enum.random(1..7), [:a, :b])
        {:ok, solvable} = Synthesis.solvable_states(domain, mode)

        for initial <- Enum.sort(MapSet.to_list(domain.states)), initial not in solvable do
          assert {:error, {:unsolvable, ^mode, witness}} =
                   Synthesis.synthesize(domain, initial, mode)

          assert initial in witness
          assert witness == Enum.sort(witness)
          assert MapSet.disjoint?(MapSet.new(witness), MapSet.new(solvable))
        end
      end
    end
  end

  describe "scaling" do
    # A 20k-state retry chain took tens of seconds with the per-layer rescans.
    # The budget is generous; it only has to catch quadratic regressions.
    @tag timeout: 60_000
    test "validation and synthesis stay near-linear on a 20k-state chain" do
      size = 20_000

      transitions =
        Map.new(0..(size - 1), fn state -> {state, %{step: [state, state + 1]}} end)

      {:ok, domain} = FOND.new(transitions, [size])
      policy = Map.new(0..(size - 1), &{&1, :step})

      {micros, results} =
        :timer.tc(fn ->
          [
            FOND.validate_policy(domain, policy, 0, :strong_cyclic),
            FOND.validate_policy(domain, policy, 0, :strong),
            Synthesis.synthesize(domain, 0, :strong_cyclic),
            Synthesis.synthesize(domain, 0, :strong)
          ]
        end)

      assert [
               {:ok, %{reachable_count: reachable}},
               {:error, %{reason: :not_strong}},
               {:ok, ^policy},
               {:error, {:unsolvable, :strong, _}}
             ] = results

      assert reachable == size + 1
      assert micros < 5_000_000, "20k-state FOND round took #{div(micros, 1000)}ms"
    end
  end

  defp random_domain(count, action_names) do
    states = Enum.to_list(0..(count - 1))
    goals = Enum.filter(states, fn _ -> :rand.uniform(4) == 1 end)

    transitions =
      Map.new(states, fn state ->
        actions =
          action_names
          |> Enum.take(Enum.random(0..length(action_names)))
          |> Map.new(fn action ->
            {action, for(_ <- 1..Enum.random(1..3), do: Enum.random(states))}
          end)

        {state, actions}
      end)

    {:ok, domain} = FOND.new(transitions, goals)
    domain
  end

  defp reference_region(domain, :strong), do: reference_attractor(domain, domain.goals, %{})

  defp reference_region(domain, :strong_cyclic),
    do: reference_cyclic(domain, domain.states)

  defp reference_attractor(domain, winning, policy) do
    layer =
      for state <- non_goal_outside(domain, winning),
          action = first(domain, state, &all_in?(domain, state, &1, winning)),
          action != nil,
          do: {state, action}

    if layer == [] do
      {winning, policy}
    else
      reference_attractor(
        domain,
        Enum.reduce(layer, winning, fn {state, _}, acc -> MapSet.put(acc, state) end),
        Enum.into(layer, policy)
      )
    end
  end

  defp reference_cyclic(domain, candidate) do
    {reached, policy} =
      reference_paths(domain, candidate, MapSet.intersection(domain.goals, candidate), %{})

    if MapSet.equal?(reached, candidate),
      do: {candidate, policy},
      else: reference_cyclic(domain, reached)
  end

  defp reference_paths(domain, candidate, reached, policy) do
    layer =
      for state <- non_goal_outside(domain, reached),
          MapSet.member?(candidate, state),
          action =
            first(domain, state, fn action ->
              all_in?(domain, state, action, candidate) and
                Enum.any?(FOND.outcomes(domain, state, action), &MapSet.member?(reached, &1))
            end),
          action != nil,
          do: {state, action}

    if layer == [] do
      {reached, policy}
    else
      reference_paths(
        domain,
        candidate,
        Enum.reduce(layer, reached, fn {state, _}, acc -> MapSet.put(acc, state) end),
        Enum.into(layer, policy)
      )
    end
  end

  defp non_goal_outside(domain, excluded) do
    domain.states
    |> MapSet.difference(excluded)
    |> MapSet.difference(domain.goals)
    |> Enum.sort()
  end

  defp first(domain, state, admitted?),
    do: domain |> FOND.actions(state) |> Enum.find(admitted?)

  defp all_in?(domain, state, action, set),
    do: Enum.all?(FOND.outcomes(domain, state, action), &MapSet.member?(set, &1))
end

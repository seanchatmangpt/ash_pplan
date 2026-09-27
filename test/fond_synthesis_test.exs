defmodule AshPPlan.FOND.SynthesisTest do
  @moduledoc """
  Chicago-style court for `AshPPlan.FOND.Synthesis`.

  Every synthesized policy is checked by the real `AshPPlan.FOND.validate_policy/4`,
  and completeness is checked against a brute-force oracle that enumerates every
  deterministic policy of a small domain and asks the same validator. No test
  double is involved: the validator is the independent admission function.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.FOND.Synthesis

  @modes [:strong, :strong_cyclic]

  # -- fixtures ---------------------------------------------------------------

  # Fair retry: :try may loop back to :pending or finish.
  defp retry_loop do
    {:ok, domain} =
      FOND.new(
        %{pending: %{try: [:pending, :done]}, done: %{}},
        [:done]
      )

    domain
  end

  # One nondeterministic branch of the only action ends in a dead end.
  defp dead_end_branch do
    {:ok, domain} =
      FOND.new(
        %{start: %{go: [:dead, :done]}, dead: %{}, done: %{}},
        [:done]
      )

    domain
  end

  # A closed self-loop with no goal path. Dropping the path-to-goal pruning
  # from the strong-cyclic fixpoint admits :trap, because :spin never leaves it.
  defp spin_trap do
    {:ok, domain} =
      FOND.new(
        %{trap: %{spin: [:trap]}, done: %{}},
        [:done]
      )

    domain
  end

  # The smallest-sorted action (:a) is unsafe only after two pruning rounds:
  # :s1's :b can fall into :dead, so :s1 is not in the fixpoint, so :a (which
  # can reach :s1) is not policy-closed. :retry is the only admissible choice.
  defp delayed_prune do
    {:ok, domain} =
      FOND.new(
        %{
          s0: %{a: [:s1, :done], retry: [:s0, :done]},
          s1: %{b: [:dead, :done]},
          dead: %{},
          done: %{}
        },
        [:done]
      )

    domain
  end

  # Same as delayed_prune without the :retry escape hatch.
  defp delayed_prune_no_escape do
    {:ok, domain} =
      FOND.new(
        %{
          s0: %{a: [:s1, :done]},
          s1: %{b: [:dead, :done]},
          dead: %{},
          done: %{}
        },
        [:done]
      )

    domain
  end

  # Strong solution needs two attractor layers and must avoid the retry action.
  defp layered_strong do
    {:ok, domain} =
      FOND.new(
        %{
          a: %{loop: [:a, :b], step: [:b, :c]},
          b: %{finish: [:done, :alt_done]},
          c: %{finish: [:done]},
          done: %{},
          alt_done: %{}
        },
        [:done, :alt_done]
      )

    domain
  end

  # -- acceptance fixtures ----------------------------------------------------

  test "retry loop is admitted for :strong_cyclic but refused for :strong" do
    domain = retry_loop()

    assert {:ok, %{pending: :try} = policy} =
             Synthesis.synthesize(domain, :pending, :strong_cyclic)

    assert {:ok, %{semantics: :strong_cyclic}} =
             FOND.validate_policy(domain, policy, :pending, :strong_cyclic)

    assert {:error, {:unsolvable, :strong, [:pending]}} =
             Synthesis.synthesize(domain, :pending, :strong)
  end

  test "a dead-end nondeterministic branch is refused for :strong_cyclic and :strong" do
    domain = dead_end_branch()

    for mode <- @modes do
      assert {:error, {:unsolvable, ^mode, [:dead, :start]}} =
               Synthesis.synthesize(domain, :start, mode)
    end
  end

  test "path-to-goal pruning refuses a closed loop with no goal path" do
    assert {:error, {:unsolvable, :strong_cyclic, [:trap]}} =
             Synthesis.synthesize(spin_trap(), :trap, :strong_cyclic)
  end

  test "outer fixpoint iterates until actions that can leave the region are pruned" do
    domain = delayed_prune()

    assert {:ok, policy} = Synthesis.synthesize(domain, :s0, :strong_cyclic)
    assert policy == %{s0: :retry}
    assert {:ok, _} = FOND.validate_policy(domain, policy, :s0, :strong_cyclic)

    assert {:error, {:unsolvable, :strong_cyclic, [:dead, :s0, :s1]}} =
             Synthesis.synthesize(delayed_prune_no_escape(), :s0, :strong_cyclic)
  end

  test "strong synthesis builds a layered attractor and never selects a looping action" do
    domain = layered_strong()

    assert {:ok, policy} = Synthesis.synthesize(domain, :a, :strong)
    assert policy == %{a: :step, b: :finish, c: :finish}
    assert {:ok, %{semantics: :strong}} = FOND.validate_policy(domain, policy, :a, :strong)

    # Strong-cyclic may pick the smaller-sorted looping action; it must still validate.
    assert {:ok, cyclic} = Synthesis.synthesize(domain, :a, :strong_cyclic)
    assert {:ok, _} = FOND.validate_policy(domain, cyclic, :a, :strong_cyclic)
  end

  test "policy is restricted to states reachable under the synthesized policy" do
    {:ok, domain} =
      FOND.new(
        %{
          start: %{go: [:done]},
          orphan: %{go: [:done]},
          done: %{}
        },
        [:done]
      )

    assert {:ok, %{start: :go} = policy} = Synthesis.synthesize(domain, :start, :strong)
    refute Map.has_key?(policy, :orphan)
    assert {:ok, [:done, :orphan, :start]} = Synthesis.solvable_states(domain, :strong)
  end

  # -- boundaries and typed refusals -------------------------------------------

  test "a goal initial state yields the empty policy in both modes" do
    domain = retry_loop()

    for mode <- @modes do
      assert {:ok, policy} = Synthesis.synthesize(domain, :done, mode)
      assert policy == %{}
      assert {:ok, _} = FOND.validate_policy(domain, policy, :done, mode)
    end
  end

  test "a non-goal initial state with no actions is refused with itself as witness" do
    {:ok, domain} = FOND.new(%{stuck: %{}, done: %{}}, [:done])

    for mode <- @modes do
      assert {:error, {:unsolvable, ^mode, [:stuck]}} = Synthesis.synthesize(domain, :stuck, mode)
    end
  end

  test "an empty goal set is unsolvable from every state" do
    {:ok, domain} = FOND.new(%{a: %{go: [:a]}}, [])

    assert {:ok, []} = Synthesis.solvable_states(domain, :strong_cyclic)
    assert {:error, {:unsolvable, :strong_cyclic, [:a]}} = Synthesis.synthesize(domain, :a)
  end

  test "request refusals are typed" do
    domain = retry_loop()

    assert {:error, {:unknown_initial_state, :nowhere}} =
             Synthesis.synthesize(domain, :nowhere, :strong)

    assert {:error, {:invalid_mode, :weak}} = Synthesis.synthesize(domain, :pending, :weak)
    assert {:error, {:invalid_mode, :weak}} = Synthesis.solvable_states(domain, :weak)
    assert {:error, {:invalid_domain, %{}}} = Synthesis.synthesize(%{}, :pending, :strong)
  end

  test "the default mode is :strong_cyclic, matching validate_policy/4" do
    assert {:ok, %{pending: :try}} = Synthesis.synthesize(retry_loop(), :pending)
  end

  test "the facade delegates to synthesis" do
    assert {:ok, %{pending: :try}} = AshPPlan.synthesize_policy(retry_loop(), :pending)

    assert {:error, {:unsolvable, :strong, [:pending]}} =
             AshPPlan.synthesize_policy(retry_loop(), :pending, :strong)
  end

  test "synthesis is deterministic" do
    domain = layered_strong()

    results = for _ <- 1..5, do: Synthesis.synthesize(domain, :a, :strong_cyclic)
    assert results |> Enum.uniq() |> length() == 1
  end

  # -- soundness and completeness against a brute-force oracle -----------------

  test "fixtures: synthesis agrees with brute-force enumeration of every policy" do
    for domain <- [
          retry_loop(),
          dead_end_branch(),
          spin_trap(),
          delayed_prune(),
          delayed_prune_no_escape(),
          layered_strong()
        ] do
      assert_agrees_with_oracle(domain)
    end
  end

  test "strong and strong-cyclic verdicts differ on the retry-loop fixture" do
    domain = retry_loop()

    refute oracle_solvable?(domain, :pending, :strong)
    assert oracle_solvable?(domain, :pending, :strong_cyclic)
  end

  test "random small domains: synthesis agrees with brute-force enumeration" do
    :rand.seed(:exsss, {26, 9, 26})

    for _ <- 1..400 do
      assert_agrees_with_oracle(random_domain())
    end
  end

  defp assert_agrees_with_oracle(domain) do
    for initial <- Enum.sort(MapSet.to_list(domain.states)), mode <- @modes do
      oracle = oracle_solvable?(domain, initial, mode)

      case Synthesis.synthesize(domain, initial, mode) do
        {:ok, policy} ->
          assert {:ok, _} = FOND.validate_policy(domain, policy, initial, mode),
                 "synthesized policy refused: #{inspect({domain, initial, mode, policy})}"

          assert oracle, "oracle found no policy: #{inspect({domain, initial, mode})}"

        {:error, {:unsolvable, ^mode, witness}} ->
          refute oracle,
                 "synthesis refused a solvable domain: #{inspect({domain, initial, mode})}"

          assert initial in witness
          assert witness == Enum.sort(witness)
          assert Enum.all?(witness, &(not MapSet.member?(domain.goals, &1)))
      end

      {:ok, solvable} = Synthesis.solvable_states(domain, mode)
      assert initial in solvable == oracle
    end
  end

  defp oracle_solvable?(domain, initial, mode) do
    domain
    |> all_policies()
    |> Enum.any?(&match?({:ok, _}, FOND.validate_policy(domain, &1, initial, mode)))
  end

  # Every total deterministic policy over non-goal states that have actions.
  defp all_policies(domain) do
    domain.states
    |> MapSet.difference(domain.goals)
    |> MapSet.to_list()
    |> Enum.sort()
    |> Enum.reject(&(FOND.actions(domain, &1) == []))
    |> Enum.reduce([%{}], fn state, policies ->
      for policy <- policies, action <- FOND.actions(domain, state) do
        Map.put(policy, state, action)
      end
    end)
  end

  defp random_domain do
    count = Enum.random(1..4)
    states = Enum.to_list(0..(count - 1))
    goals = Enum.filter(states, fn _ -> :rand.uniform(3) == 1 end)

    transitions =
      Map.new(states, fn state ->
        actions =
          [:a, :b]
          |> Enum.take(Enum.random(0..2))
          |> Map.new(fn action ->
            outcomes = for _ <- 1..Enum.random(1..3), do: Enum.random(states)
            {action, outcomes}
          end)

        {state, actions}
      end)

    {:ok, domain} = FOND.new(transitions, goals)
    domain
  end
end

defmodule AshPPlan.FOND.WorkOrderLifecycleFONDTest do
  @moduledoc """
  Chicago-style court for the NatFac work-order lifecycle modelled as a FOND
  domain (ARD Tier 2 §3).

  Real collaborators only: `AshPPlan.synthesize_policy/3` constructs the
  policy, `AshPPlan.validate_policy/4` is the independent admission function,
  and a test-local BFS over the policy graph re-derives "every reachable state
  has a path to :closed" without consulting the validator's report. The
  mutation fixtures prove the bidding fallback edge is load-bearing: removing
  or stalling it flips both synthesis and validation to typed refusals.

  The TLC differential block runs the pinned tla2tools jar as a real java
  subprocess and skips loudly when the jar is absent.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.Test.TLCCourt
  alias AshPPlan.Test.WorkOrderLifecycleFOND, as: Lifecycle

  @initial :intake
  @goal :closed

  # Stage -> the state that witnesses the stage in the FOND state space.
  @stage_states %{
    intake: :intake,
    dispatch: :dispatched,
    arrival: :arrived,
    approval: :approved,
    verification: :verified,
    settlement: :settled,
    closed: :closed
  }

  describe "domain shape" do
    test "the fixture carries the seven lifecycle stages and three nondeterministic actions" do
      domain = Lifecycle.domain()

      assert length(Lifecycle.stages()) == 7
      assert Enum.sort(Lifecycle.stages()) == Enum.sort(Map.keys(@stage_states))

      for stage <- Lifecycle.stages() do
        assert MapSet.member?(domain.states, Map.fetch!(@stage_states, stage)),
               "stage #{stage} has no state in the domain"
      end

      assert FOND.outcomes(domain, :intake, :fanout) == [:dispatched, :no_show]
      assert FOND.outcomes(domain, :arrived, :quote) == [:over_nte, :quoted_within_nte]

      assert FOND.outcomes(domain, :quoted_within_nte, :request_approval) ==
               [:approval_delayed, :approved]

      # bidding fallback edge: exception re-enters the approval stage
      assert FOND.outcomes(domain, :exception, :bidding) == [:quoted_within_nte]

      assert domain.goals == MapSet.new([@goal])
      assert FOND.check(domain) == :ok
    end
  end

  describe "strong-cyclic synthesis on the intact lifecycle" do
    test "synthesize :strong_cyclic succeeds with the pinned policy" do
      domain = Lifecycle.domain()

      assert {:ok, policy} = AshPPlan.synthesize_policy(domain, @initial, :strong_cyclic)
      assert policy == Lifecycle.expected_policy()
    end

    test "validate_policy admits the synthesized policy and reaches every state" do
      domain = Lifecycle.domain()
      {:ok, policy} = AshPPlan.synthesize_policy(domain, @initial, :strong_cyclic)

      assert {:ok, report} = AshPPlan.validate_policy(domain, policy, @initial, :strong_cyclic)
      assert report.semantics == :strong_cyclic
      assert report.initial == @initial
      assert report.ignored_policy_states == []

      # Every state in the domain (all 12) is reachable under the policy.
      assert report.reachable_states == domain.states |> MapSet.to_list() |> Enum.sort()
      assert report.reachable_count == MapSet.size(domain.states)

      # Every lifecycle stage is actually visited, not just declared.
      for {_stage, state} <- @stage_states do
        assert state in report.reachable_states
      end
    end

    test "every reachable state has a path to :closed (independent BFS, not the validator)" do
      domain = Lifecycle.domain()
      {:ok, policy} = AshPPlan.synthesize_policy(domain, @initial, :strong_cyclic)

      reachable = forward_reachable(domain, policy, @initial)
      assert MapSet.member?(reachable, @goal)

      for state <- reachable do
        assert path_to_goal?(domain, policy, state, @goal),
               "state #{inspect(state)} is reachable under the policy but has no path to #{@goal}"
      end

      # The retry/await/bidding loops really are loops: the policy graph has
      # back edges, so the path-to-goal claim is a fairness claim, not trivial.
      assert :intake in FOND.outcomes(domain, :no_show, policy.no_show)

      assert :quoted_within_nte in FOND.outcomes(
               domain,
               :approval_delayed,
               policy.approval_delayed
             )

      assert :quoted_within_nte in FOND.outcomes(domain, :exception, policy.exception)
    end

    test "the lifecycle is :strong_cyclic-solvable but not :strong-solvable" do
      domain = Lifecycle.domain()
      {:ok, policy} = AshPPlan.synthesize_policy(domain, @initial, :strong_cyclic)

      # :strong synthesis refuses: the retry, await and bidding loops mean no
      # execution bound exists without fairness. Witness = every reachable
      # state outside the strong attractor {approved, verified, settled, closed}.
      assert {:error, {:unsolvable, :strong, witness}} =
               AshPPlan.synthesize_policy(domain, @initial, :strong)

      assert witness == [
               :approval_delayed,
               :arrived,
               :dispatched,
               :exception,
               :intake,
               :no_show,
               :over_nte,
               :quoted_within_nte
             ]

      # The same policy validated under :strong is refused with the same losing set.
      assert {:error, %{reason: :not_strong, initial: @initial, losing_states: losing}} =
               AshPPlan.validate_policy(domain, policy, @initial, :strong)

      assert losing == witness

      # ... while under :strong_cyclic it is admitted.
      assert {:ok, _} = AshPPlan.validate_policy(domain, policy, @initial, :strong_cyclic)
    end
  end

  describe "mutation: the bidding fallback edge is load-bearing" do
    test "removing the bidding edge makes :exception a dead end and synthesis refuses" do
      mutated = Lifecycle.mutations().bidding_removed

      assert FOND.actions(mutated, :exception) == []

      assert {:error, {:unsolvable, :strong_cyclic, witness}} =
               AshPPlan.synthesize_policy(mutated, @initial, :strong_cyclic)

      # Everything upstream of the exception is pruned; the approval tail survives.
      assert witness == [:arrived, :dispatched, :exception, :intake, :no_show, :over_nte]
      assert :quoted_within_nte not in witness
      assert :approved not in witness
    end

    test "removing the bidding edge: the intact policy is refused as :unavailable_policy_action" do
      mutated = Lifecycle.mutations().bidding_removed
      policy = Lifecycle.expected_policy()

      assert {:error,
              %{
                reason: :unavailable_policy_action,
                state: :exception,
                action: :bidding,
                available: []
              }} = AshPPlan.validate_policy(mutated, policy, @initial, :strong_cyclic)
    end

    test "removing the bidding edge: a policy with no decision at :exception is :missing_policy_action" do
      mutated = Lifecycle.mutations().bidding_removed
      policy = Map.delete(Lifecycle.expected_policy(), :exception)

      assert {:error, %{reason: :missing_policy_action, state: :exception}} =
               AshPPlan.validate_policy(mutated, policy, @initial, :strong_cyclic)
    end

    test "stalling the bidding edge (self-loop) is refused as :not_strong_cyclic" do
      mutated = Lifecycle.mutations().bidding_stalls
      policy = Map.put(Lifecycle.expected_policy(), :exception, :stall)

      # The policy is total and every action is admitted, so the refusal is
      # the goal-path law itself, not a shape error.
      assert {:error,
              %{
                reason: :not_strong_cyclic,
                initial: @initial,
                states_without_goal_path: stuck
              }} = AshPPlan.validate_policy(mutated, policy, @initial, :strong_cyclic)

      # validate_policy reports per-state goal reachability: only the two states
      # on the stalled branch have no path at all. Upstream states (arrived,
      # dispatched, intake, no_show) still have a fair path via the within-NTE
      # branch, so they are not "without goal path".
      assert stuck == [:exception, :over_nte]

      # Synthesis is stricter: it prunes actions that can leave the winning
      # region, so :quote (which may land in :over_nte) is not policy-closed and
      # everything upstream of the exception is unsolvable.
      assert {:error, {:unsolvable, :strong_cyclic, witness}} =
               AshPPlan.synthesize_policy(mutated, @initial, :strong_cyclic)

      assert witness == [:arrived, :dispatched, :exception, :intake, :no_show, :over_nte]
      assert MapSet.subset?(MapSet.new(stuck), MapSet.new(witness))
    end

    test "the intact domain and both mutations differ only at :exception" do
      intact = Lifecycle.transitions()

      for {_name, mutated} <- Lifecycle.mutations() do
        assert Map.delete(mutated.transitions, :exception) ==
                 Map.delete(Lifecycle.domain().transitions, :exception)

        refute mutated.transitions.exception == intact.exception
      end
    end
  end

  describe "TLC differential court (tla2tools 1.7.4, real java subprocess)" do
    case TLCCourt.availability() do
      :ok -> @describetag :tlc
      {:unavailable, reason} -> @describetag skip: "TLC court unavailable: " <> reason
    end

    test "TLC agrees: strong_cyclic admitted, strong refused, bidding-stall refused" do
      domain = Lifecycle.domain()
      {:ok, policy} = AshPPlan.synthesize_policy(domain, @initial, :strong_cyclic)

      {:ok, cyclic} = FOND.to_tla(domain, policy, @initial, :strong_cyclic)
      assert %{verdict: :admitted} = TLCCourt.check!(cyclic)

      {:ok, strong} = FOND.to_tla(domain, policy, @initial, :strong)
      assert %{verdict: :refused} = TLCCourt.check!(strong)

      mutated = Lifecycle.mutations().bidding_stalls
      stalled_policy = Map.put(policy, :exception, :stall)
      {:ok, stalled} = FOND.to_tla(mutated, stalled_policy, @initial, :strong_cyclic)
      assert %{verdict: :refused} = TLCCourt.check!(stalled)
    end
  end

  # -- test-local graph helpers (independent of validate_policy) ---------------

  defp forward_reachable(domain, policy, initial) do
    bfs(domain, policy, [initial], MapSet.new())
  end

  defp bfs(_domain, _policy, [], seen), do: seen

  defp bfs(domain, policy, [state | rest], seen) do
    cond do
      MapSet.member?(seen, state) ->
        bfs(domain, policy, rest, seen)

      MapSet.member?(domain.goals, state) ->
        bfs(domain, policy, rest, MapSet.put(seen, state))

      true ->
        successors = FOND.outcomes(domain, state, Map.fetch!(policy, state))
        bfs(domain, policy, rest ++ successors, MapSet.put(seen, state))
    end
  end

  defp path_to_goal?(domain, policy, from, goal) do
    MapSet.member?(forward_reachable(domain, policy, from), goal)
  end
end

defmodule AshPPlan.FOND.SemanticRealityCourtTest do
  @moduledoc """
  Court for README item 7: `AshPPlan.FOND` validates or synthesizes candidate
  strong and strong-cyclic policies WITHOUT actuating them.

  Chicago style: real domains (plain data), real validation and synthesis
  calls, assertions on final state. No actuation side effects exist because
  the whole layer is pure — the court proves it by determinism across
  repeated calls and by inspection of the result terms.
  """

  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.FOND.Synthesis

  # Domain: a coin flip retry loop. `:attempt` from `:pending` may succeed or
  # stay `:pending` — no deterministic policy exists, so only `:strong_cyclic`
  # semantics can admit a policy here.
  defmodule NondeterministicDomain do
    def transitions do
      %{
        pending: %{attempt: [:pending, :succeeded]},
        succeeded: %{}
      }
    end

    def goals, do: [:succeeded]
    def initial, do: :pending
  end

  # Domain with an unavoidable dead end: from `:walking`, `:step` may reach
  # `:pit` (goal-adjacent but not a goal, with no outgoing action), or the
  # goal `:summit`. Nothing in `:pit` is playable, so the domain is not
  # solvable from `:walking`.
  defmodule DeadEndDomain do
    def transitions do
      %{
        walking: %{step: [:pit, :summit]},
        pit: %{},
        summit: %{}
      }
    end

    def goals, do: [:summit]
    def initial, do: :walking
    def dead_end, do: :pit
  end

  describe "validate/4 — known-strong policy" do
    test "a policy where every outcome reaches the goal validates under :strong" do
      {:ok, domain} =
        FOND.new(
          %{
            ready: %{fire: [:succeeded]},
            succeeded: %{}
          },
          [:succeeded]
        )

      policy = %{ready: :fire}

      assert {:ok, report} = FOND.validate_policy(domain, policy, :ready, :strong)
      assert report.semantics == :strong
      assert report.initial == :ready
      assert report.reachable_states == [:ready, :succeeded]
      assert report.reachable_count == 2
      assert report.ignored_policy_states == []
    end

    test "the same known-strong policy also validates under the default mode" do
      {:ok, domain} =
        FOND.new(
          %{
            ready: %{fire: [:succeeded]},
            succeeded: %{}
          },
          [:succeeded]
        )

      assert {:ok, report} = FOND.validate_policy(domain, %{ready: :fire}, :ready)
      assert report.semantics == :strong_cyclic
    end

    test "a retry policy is refused as :not_strong but admitted as :strong_cyclic" do
      {:ok, domain} =
        FOND.new(NondeterministicDomain.transitions(), NondeterministicDomain.goals())

      policy = %{pending: :attempt}

      assert {:error, error} = FOND.validate_policy(domain, policy, :pending, :strong)
      assert error.reason == :not_strong
      assert error.losing_states == [:pending]

      assert {:ok, report} = FOND.validate_policy(domain, policy, :pending, :strong_cyclic)
      assert report.semantics == :strong_cyclic
      assert report.reachable_states == [:pending, :succeeded]
    end
  end

  describe "synthesize/3 — strong-cyclic existence under nondeterminism" do
    test "a strong-cyclic policy exists for the coin-flip domain and validates" do
      {:ok, domain} =
        FOND.new(NondeterministicDomain.transitions(), NondeterministicDomain.goals())

      assert {:ok, policy} = Synthesis.synthesize(domain, :pending, :strong_cyclic)
      assert policy == %{pending: :attempt}

      # The synthesized policy is exactly what validate_policy/4 admits.
      assert {:ok, report} =
               FOND.validate_policy(domain, policy, :pending, :strong_cyclic)

      assert report.reachable_count == 2
    end

    test "strong synthesis refuses the nondeterministic domain; strong_cyclic succeeds" do
      {:ok, domain} =
        FOND.new(NondeterministicDomain.transitions(), NondeterministicDomain.goals())

      assert {:error, {:unsolvable, :strong, witnesses}} =
               Synthesis.synthesize(domain, :pending, :strong)

      assert :pending in witnesses

      assert {:ok, _policy} = Synthesis.synthesize(domain, :pending, :strong_cyclic)
    end

    test "solvable_states/2 reports the winning region for both modes" do
      {:ok, domain} =
        FOND.new(NondeterministicDomain.transitions(), NondeterministicDomain.goals())

      assert {:ok, strong} = Synthesis.solvable_states(domain, :strong)
      assert strong == [:succeeded]

      assert {:ok, strong_cyclic} = Synthesis.solvable_states(domain, :strong_cyclic)
      assert strong_cyclic == [:pending, :succeeded]
    end

    test "a deterministic domain yields a strong policy directly" do
      {:ok, domain} =
        FOND.new(
          %{
            a: %{go: [:b]},
            b: %{go: [:goal]},
            goal: %{}
          },
          [:goal]
        )

      assert {:ok, policy} = Synthesis.synthesize(domain, :a, :strong)
      assert policy == %{a: :go, b: :go}

      assert {:ok, _} = FOND.validate_policy(domain, policy, :a, :strong)
    end
  end

  describe "purity — no actuation side effects" do
    test "validate_policy is deterministic across repeated calls" do
      {:ok, domain} =
        FOND.new(NondeterministicDomain.transitions(), NondeterministicDomain.goals())

      policy = %{pending: :attempt}

      results =
        for _ <- 1..10 do
          FOND.validate_policy(domain, policy, :pending, :strong_cyclic)
        end

      assert Enum.uniq(results) == [hd(results)]
      assert match?({:ok, _}, hd(results))
    end

    test "synthesize is deterministic across repeated calls" do
      {:ok, domain} =
        FOND.new(NondeterministicDomain.transitions(), NondeterministicDomain.goals())

      results =
        for _ <- 1..10 do
          Synthesis.synthesize(domain, :pending, :strong_cyclic)
        end

      assert Enum.uniq(results) == [hd(results)]
      assert {:ok, policy} = hd(results)
      assert is_map(policy)
      # A policy is pure data: state => action atoms. No pid, no ref, no
      # function, no process handle — nothing that could carry actuation.
      Enum.each(policy, fn {state, action} ->
        assert is_atom(state)
        assert is_atom(action)
      end)
    end

    test "domain structs are unchanged by validation and synthesis" do
      {:ok, domain} =
        FOND.new(NondeterministicDomain.transitions(), NondeterministicDomain.goals())

      snapshot = domain
      policy = %{pending: :attempt}

      {:ok, _} = FOND.validate_policy(domain, policy, :pending, :strong_cyclic)
      {:ok, _} = Synthesis.synthesize(domain, :pending, :strong_cyclic)
      {:ok, _} = Synthesis.solvable_states(domain, :strong)

      assert domain == snapshot
      assert :erlang.phash2(domain) == :erlang.phash2(snapshot)
    end

    test "no processes are started by validation or synthesis" do
      {:ok, domain} =
        FOND.new(NondeterministicDomain.transitions(), NondeterministicDomain.goals())

      before = Process.registered() |> Enum.sort()

      {:ok, _} = FOND.validate_policy(domain, %{pending: :attempt}, :pending, :strong_cyclic)
      {:ok, _} = Synthesis.synthesize(domain, :pending, :strong_cyclic)

      # Give any stray (theoretically impossible) spawn a beat, then compare.
      # The FOND layer is pure data manipulation; the registry must not move.
      assert Process.registered() |> Enum.sort() == before
    end
  end

  describe "anti-vacuity — dead-end refusals" do
    test "a policy routing into a dead-end state fails :strong validation, naming the state" do
      {:ok, domain} =
        FOND.new(DeadEndDomain.transitions(), DeadEndDomain.goals())

      # The walk reaches :pit, which has no admitted action and no policy
      # decision — the refusal is typed and names the dead-end state.
      for mode <- [:strong, :strong_cyclic] do
        assert {:error, error} = FOND.validate_policy(domain, %{walking: :step}, :walking, mode)
        assert error.reason == :missing_policy_action
        assert error.state == DeadEndDomain.dead_end()
      end
    end

    test "a losing cycle is refused as :not_strong naming the losing state" do
      # Loop forever between :a and :b; the goal is only reachable via :detour.
      {:ok, domain} =
        FOND.new(
          %{
            a: %{loop: [:b], detour: [:goal]},
            b: %{loop: [:a]},
            goal: %{}
          },
          [:goal]
        )

      assert {:error, error} = FOND.validate_policy(domain, %{a: :loop, b: :loop}, :a, :strong)
      assert error.reason == :not_strong
      assert Enum.sort(error.losing_states) == [:a, :b]

      assert {:error, sc_error} =
               FOND.validate_policy(domain, %{a: :loop, b: :loop}, :a, :strong_cyclic)

      assert sc_error.reason == :not_strong_cyclic
      assert Enum.sort(sc_error.states_without_goal_path) == [:a, :b]
    end

    test "the dead-end state itself is refused: no policy action exists for it" do
      {:ok, domain} =
        FOND.new(DeadEndDomain.transitions(), DeadEndDomain.goals())

      dead_end = DeadEndDomain.dead_end()
      policy = %{walking: :step, pit: :step}

      # An action not admitted in a reachable state is refused, naming the
      # state (:pit) and the action.
      assert {:error, error} = FOND.validate_policy(domain, policy, :walking, :strong)
      assert error.reason == :unavailable_policy_action
      assert error.state == dead_end
      assert error.action == :step
      assert error.available == []
    end

    test "synthesis refuses the dead-end domain with a typed unsolvable witness" do
      {:ok, domain} =
        FOND.new(DeadEndDomain.transitions(), DeadEndDomain.goals())

      for mode <- [:strong, :strong_cyclic] do
        assert {:error, {:unsolvable, ^mode, witnesses}} =
                 Synthesis.synthesize(domain, :walking, mode)

        assert DeadEndDomain.dead_end() in witnesses
        assert DeadEndDomain.initial() in witnesses
      end
    end

    test "an empty outcome list in a hand-built domain is refused, not vacuously admitted" do
      domain = %FOND{
        states: MapSet.new([:a, :goal]),
        goals: MapSet.new([:goal]),
        transitions: %{a: %{go: []}, goal: %{}}
      }

      assert {:error, {:invalid_domain, error}} =
               Synthesis.synthesize(domain, :a, :strong_cyclic)

      assert error.reason == :invalid_domain
      assert error.detail == :unnormalized_transitions

      assert {:error, validation_error} =
               FOND.validate_policy(domain, %{a: :go}, :a, :strong_cyclic)

      assert validation_error.reason == :invalid_domain
    end

    test "missing policy action on a reachable state is refused, naming the state" do
      {:ok, domain} =
        FOND.new(NondeterministicDomain.transitions(), NondeterministicDomain.goals())

      assert {:error, error} = FOND.validate_policy(domain, %{}, :pending, :strong_cyclic)
      assert error.reason == :missing_policy_action
      assert error.state == :pending
    end
  end

  describe "domain hygiene" do
    test "new/2 refuses an empty nondeterministic outcome list at construction" do
      assert {:error, error} = FOND.new(%{a: %{go: []}}, [:a])
      assert error.reason == :empty_nondeterministic_outcome
      assert error.state == :a
      assert error.action == :go
    end

    test "check/1 admits a normalized domain and refuses an undeclared state" do
      {:ok, domain} =
        FOND.new(NondeterministicDomain.transitions(), NondeterministicDomain.goals())

      assert FOND.check(domain) == :ok

      rogue = %FOND{
        states: MapSet.new([:pending, :succeeded]),
        goals: MapSet.new([:succeeded]),
        transitions: %{pending: %{attempt: [:offworld, :pending]}, succeeded: %{}}
      }

      assert {:error, error} = FOND.check(rogue)
      assert error.reason == :invalid_domain
      assert error.detail == :undeclared_states
      assert :offworld in error.states
    end
  end
end

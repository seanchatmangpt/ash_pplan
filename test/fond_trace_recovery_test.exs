defmodule AshPPlan.FONDTraceRecoveryTest do
  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.FOND.{Recovery, Trace}

  test "shortest goal trace is deterministic" do
    {:ok, domain} =
      FOND.new(%{
        a: %{go: [:b, :c]},
        b: %{go: [:done]},
        c: %{go: [:dead]},
        dead: %{},
        done: %{}
      }, [:done])

    policy = %{a: :go, b: :go, c: :go}

    assert {:ok, [:a, :b, :done]} = Trace.shortest_goal_path(domain, policy, :a)
    assert Enum.any?(Trace.edges(domain, policy), &(&1.from == :a and &1.to == :b))
  end

  test "recovery routes strong liveness refusal to strong cyclic" do
    route = Recovery.route(%{reason: :not_strong, losing_states: [:pending]})
    assert route.action == :try_strong_cyclic
    assert route.preserve_subject
  end

  test "identity and shape failures never preserve subject" do
    refute Recovery.route(%{reason: :unknown_initial_state}).preserve_subject
    refute Recovery.route(%{reason: :invalid_policy_request}).preserve_subject
  end
end

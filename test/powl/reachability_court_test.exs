defmodule AshPPlan.POWL.ReachabilityCourtTest do
  use ExUnit.Case, async: true

  alias AshPPlan.POWL
  alias AshPPlan.POWL.Reachability
  alias AshPPlan.POWL.Verifier

  @moduledoc """
  T-006 property court. Real AST models, real simulation, no mocks. A
  court that cannot exhibit the deadlock is FAIL (vacuous court).
  """

  test "known unsound loop-with-choice model deadlocks under simulation and is refused" do
    model = POWL.loop("l1", POWL.choice("c1", [POWL.activity("a"), POWL.activity("b")]), POWL.activity("c"))

    verdict = Reachability.simulate!(model)

    assert verdict.outcome == :deadlock
    assert verdict.deadlocks != []
    assert verdict.final_reachable == false

    assert {:error, %{reason: :loop_choice_body, block: %{block_id: "l1"}}} =
             Verifier.verify(model)
  end

  test "sound reference model has zero deadlocks and zero orphan tokens" do
    model =
      POWL.sequence("s1", [
        POWL.activity("a"),
        POWL.choice("c1", [POWL.activity("b"), POWL.activity("c")])
      ])

    verdict = Reachability.simulate!(model)

    assert verdict.outcome == :sound
    assert verdict.deadlocks == []
    assert verdict.orphans == []
    assert verdict.final_reachable == true
    assert verdict.budget_exhausted == false

    assert Verifier.verify(model) == :ok
  end

  test "redo-only cycle is reported unbounded, not silently passed" do
    model = POWL.loop("l1", POWL.activity("a"), POWL.activity("skip"))

    verdict = Reachability.simulate!(model)

    assert verdict.outcome == :unbounded
    assert verdict.deadlocks == []
    assert verdict.final_reachable == false
    assert verdict.budget_exhausted == false
  end
end

defmodule AshPPlan.FOND.Supervision.FailureTest do
  use ExUnit.Case, async: true
  alias AshPPlan.FOND.Supervision.Failure
  test "classifies local refusal and edge" do
    assert Failure.classify(:invalid_candidate)==:local; assert Failure.classify({:authority_bearing_policy,:do})==:refused; assert Failure.classify(:timeout)==:edge
  end
end

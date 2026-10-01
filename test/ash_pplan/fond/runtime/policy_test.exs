defmodule AshPPlan.FOND.Runtime.PolicyTest do
  use ExUnit.Case, async: true
  alias AshPPlan.FOND.Runtime.Policy

  test "attempt budget is bounded" do
    p = Policy.new(max_attempts: 2)
    assert Policy.attempt_allowed?(p, 1)
    refute Policy.attempt_allowed?(p, 2)
  end
end

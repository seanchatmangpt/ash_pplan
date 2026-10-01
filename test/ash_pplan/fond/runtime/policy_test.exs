defmodule AshPPlan.FOND.Runtime.PolicyTest do
 use ExUnit.Case, async: true
 alias AshPPlan.FOND.Runtime.Policy
 test "attempt budget is bounded" do p=Policy.new(max_attempts: 2); assert p.attempt_allowed?(1); refute p.attempt_allowed?(2) end
end
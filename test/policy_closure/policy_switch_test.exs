defmodule AshPPlan.PolicyClosure.PolicySwitchTest do
  use ExUnit.Case, async: true
  alias AshPPlan.PolicyClosure.PolicySwitch
  test "construct only", do: assert(PolicySwitch.decide(:a, :b, :why).authority == :construct)
end

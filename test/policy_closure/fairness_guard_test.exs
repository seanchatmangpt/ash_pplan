defmodule AshPPlan.PolicyClosure.FairnessGuardTest do
 use ExUnit.Case, async: true
 alias AshPPlan.PolicyClosure.FairnessGuard
 test "bounds modes", do: assert {:error,:unsupported_fairness}=FairnessGuard.admit(:weak)
end

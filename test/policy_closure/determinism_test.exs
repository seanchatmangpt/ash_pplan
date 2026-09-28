defmodule AshPPlan.PolicyClosure.DeterminismTest do
 use ExUnit.Case, async: true
 alias AshPPlan.PolicyClosure.Determinism
 test "detects divergence", do: refute Determinism.stable?(%{a: 1},%{a: 2})
end

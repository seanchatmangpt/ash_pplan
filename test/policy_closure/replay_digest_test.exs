defmodule AshPPlan.PolicyClosure.ReplayDigestTest do
 use ExUnit.Case, async: true
 alias AshPPlan.PolicyClosure.ReplayDigest
 test "stable", do: assert ReplayDigest.digest(%{a: 1})==ReplayDigest.digest(%{a: 1})
end

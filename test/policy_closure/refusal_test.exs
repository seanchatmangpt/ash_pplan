defmodule AshPPlan.PolicyClosure.RefusalTest do
 use ExUnit.Case, async: true
 alias AshPPlan.PolicyClosure.Refusal
 test "no authority", do: assert Refusal.new("s",:bad).authority==:none
end

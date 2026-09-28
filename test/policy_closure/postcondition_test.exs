defmodule AshPPlan.PolicyClosure.PostconditionTest do
 use ExUnit.Case, async: true
 alias AshPPlan.PolicyClosure.Postcondition
 test "falsifies mismatch", do: assert {:error,_}=Postcondition.check(:ok,:bad)
end

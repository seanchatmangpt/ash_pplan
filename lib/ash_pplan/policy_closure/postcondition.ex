defmodule AshPPlan.PolicyClosure.Postcondition do
 def check(expected,expected), do: :ok
 def check(expected,observed), do: {:error,%{expected: expected,observed: observed}}
end

defmodule AshPPlan.PolicyClosure.FairnessGuard do
 def admit(x) when x in [:strong,:strong_cyclic], do: :ok
 def admit(_), do: {:error,:unsupported_fairness}
end

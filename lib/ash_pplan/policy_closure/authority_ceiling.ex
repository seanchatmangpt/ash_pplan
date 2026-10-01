defmodule AshPPlan.PolicyClosure.AuthorityCeiling do
 def admit(x) when x in [:observe,:select,:construct], do: {:ok,x}
 def admit(_), do: {:error,:authority_ceiling}
end

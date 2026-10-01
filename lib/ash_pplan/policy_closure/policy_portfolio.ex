defmodule AshPPlan.PolicyClosure.PolicyPortfolio do
 def rank(xs), do: Enum.sort_by(xs,fn x->{Map.get(x,:cost,0),inspect(Map.get(x,:id))} end)
end

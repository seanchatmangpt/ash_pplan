defmodule AshPPlan.PolicyClosure.Compatibility do
 def compatible?(a,b), do: Map.get(a,:schema)==Map.get(b,:schema) and Map.get(a,:source_sha)==Map.get(b,:source_sha)
end

defmodule AshPPlan.PolicyClosure.Recovery do
 def route(:liveness_unproven), do: :resynthesize
 def route(:stale_subject), do: :rebind
 def route(_), do: :refuse
end

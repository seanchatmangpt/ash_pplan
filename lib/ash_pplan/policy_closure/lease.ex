defmodule AshPPlan.PolicyClosure.Lease do
 def valid?(epoch,expires_at_epoch), do: epoch<=expires_at_epoch
end

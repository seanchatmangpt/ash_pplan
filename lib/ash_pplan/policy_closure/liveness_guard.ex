defmodule AshPPlan.PolicyClosure.LivenessGuard do
  def admit(:live), do: :ok
  def admit(_), do: {:error, :liveness_unproven}
end

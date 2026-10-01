defmodule AshPPlan.PolicyClosure.Idempotence do
  alias AshPPlan.PolicyClosure.ReplayDigest
  def key(subject_id, operation), do: ReplayDigest.digest({subject_id, operation})
end

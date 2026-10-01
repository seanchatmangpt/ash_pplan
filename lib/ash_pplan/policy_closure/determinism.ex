defmodule AshPPlan.PolicyClosure.Determinism do
  alias AshPPlan.PolicyClosure.ReplayDigest
  def stable?(left, right), do: ReplayDigest.digest(left) == ReplayDigest.digest(right)
end

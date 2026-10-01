defmodule AshPPlan.PolicyClosure.PolicySwitch do
  def decide(from, to, reason), do: %{from: from, to: to, reason: reason, authority: :construct}
end

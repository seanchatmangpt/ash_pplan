defmodule AshPPlan.PolicyClosure.ExactSubject do
  def bind(planner, policy, state, source_sha), do: %{planner: planner, policy: policy, state: state, source_sha: source_sha}
end

defmodule AshPPlan.PolicyClosure.PrimaryConsumer do
  def project(subject_id, policy),
    do: %{consumer: :primary, subject_id: subject_id, policy: policy, authority: :none}
end

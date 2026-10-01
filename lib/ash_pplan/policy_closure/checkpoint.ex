defmodule AshPPlan.PolicyClosure.Checkpoint do
  def new(subject_id, policy_id, ordinal),
    do: %{subject_id: subject_id, policy_id: policy_id, ordinal: ordinal}
end

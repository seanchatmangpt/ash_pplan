defmodule AshPPlan.PolicyClosure.Refusal do
 def new(subject_id,reason), do: %{subject_id: subject_id,reason: reason,authority: :none}
end

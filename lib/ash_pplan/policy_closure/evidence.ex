defmodule AshPPlan.PolicyClosure.Evidence do
 def admit(subject_id,%{subject_id: subject_id}=evidence), do: {:ok,evidence}
 def admit(_, _), do: {:error,:subject_mismatch}
end

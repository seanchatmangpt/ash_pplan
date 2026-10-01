defmodule AshPPlan.PolicyClosure.Migration do
 def v1_to_v2(old), do: Map.merge(%{schema: "ash_pplan/policy-closure/v2"},Map.take(old,[:subject_id,:policy,:source_sha]))
end

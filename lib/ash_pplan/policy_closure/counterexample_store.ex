defmodule AshPPlan.PolicyClosure.CounterexampleStore do
 def put(subject_id,class,witness), do: %{subject_id: subject_id,class: class,witness: witness}
end

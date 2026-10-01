defmodule AshPPlan.PolicyClosure.SimulationConsumer do
 def project(subject_id,candidates), do: %{consumer: :simulation,subject_id: subject_id,candidates: candidates,authority: :none}
end

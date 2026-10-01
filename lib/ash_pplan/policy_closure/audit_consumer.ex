defmodule AshPPlan.PolicyClosure.AuditConsumer do
 def project(subject_id,evidence), do: %{consumer: :audit,subject_id: subject_id,evidence: evidence,authority: :none}
end

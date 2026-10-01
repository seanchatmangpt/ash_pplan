defmodule AshPPlan.FOND.Supervision.Validator do
  alias AshPPlan.FOND
  alias AshPPlan.FOND.Supervision.Candidate

  def validate(domain, initial, %Candidate{} = c) do
    case FOND.validate_policy(domain, c.policy, initial, c.semantics) do
      {:ok, report} -> {:ok, %{candidate: c, report: report}}
      {:error, reason} -> {:error, %{candidate_id: c.id, reason: reason}}
    end
  end
end

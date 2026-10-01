defmodule AshPPlan.FOND.Supervision.Preference do
  alias AshPPlan.FOND.Supervision.Candidate
  def choose([]), do: {:error,:no_admissible_policy}
  def choose(candidates), do: {:ok,Enum.min_by(candidates,&Candidate.stable_key/1)}
end

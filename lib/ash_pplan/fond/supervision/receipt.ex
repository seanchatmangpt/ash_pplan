defmodule AshPPlan.FOND.Supervision.Receipt do
  def selection(c,bad,set), do: %{event: :policy_selected,candidate_id:c.id,semantics:c.semantics,refused:bad,excluded:set|>MapSet.to_list()|>Enum.sort()}
  def refusal(r), do: %{event: :policy_refused,reason:r}
end

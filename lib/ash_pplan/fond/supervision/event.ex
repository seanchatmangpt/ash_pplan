defmodule AshPPlan.FOND.Supervision.Event do
  def selected(id), do: %{type: :selected,policy_id:id}
  def refused(id,r), do: %{type: :refused,policy_id:id,reason:r}
  def observed(id,o), do: %{type: :observed,policy_id:id,outcome:o}
end

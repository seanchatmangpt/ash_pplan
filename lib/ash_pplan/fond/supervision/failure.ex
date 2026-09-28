defmodule AshPPlan.FOND.Supervision.Failure do
  def classify(r) when r in [:invalid_observation,:invalid_candidate], do: :local
  def classify({:authority_bearing_policy,_}), do: :refused
  def classify(_), do: :edge
end

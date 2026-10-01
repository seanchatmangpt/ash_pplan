defmodule AshPPlan.FOND.Supervision.ExclusionSet do
  def new, do: MapSet.new()
  def exclude(set, id), do: MapSet.put(set, id)
  def excluded?(set, id), do: MapSet.member?(set, id)
  def filter(candidates, set), do: Enum.reject(candidates, &excluded?(set, &1.id))
end

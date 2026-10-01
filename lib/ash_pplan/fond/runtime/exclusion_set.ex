defmodule AshPPlan.FOND.Runtime.ExclusionSet do
  def new, do: MapSet.new()
  def add(s, id), do: MapSet.put(s, id)
  def member?(s, id), do: MapSet.member?(s, id)
  def merge(a, b), do: MapSet.union(a, b)
end

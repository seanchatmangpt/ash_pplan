defmodule AshPPlan.FOND.Runtime.Reconciler do
  def reconcile(desired, observed) do
    d = MapSet.new(desired, & &1.id)
    o = MapSet.new(observed, & &1.id)
    %{start: MapSet.difference(d, o), stop: MapSet.difference(o, d)}
  end
end

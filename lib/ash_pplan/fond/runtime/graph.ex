defmodule AshPPlan.FOND.Runtime.Graph do
  alias AshPPlan.FOND.Runtime.Edge
  defstruct edges: %{}, excluded: MapSet.new()
  def new(es), do: %__MODULE__{edges: Map.new(es, &{&1.id, &1})}
  def exclude(g, id), do: %{g | excluded: MapSet.put(g.excluded, id)}

  def candidates(g, c),
    do: g.edges |> Map.values() |> Enum.filter(&Edge.eligible?(&1, c, g.excluded))

  def exhausted?(g, c), do: candidates(g, c) == []
end

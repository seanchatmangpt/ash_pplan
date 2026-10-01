defmodule AshPPlan.FOND.Runtime.Recovery do
  alias AshPPlan.FOND.Runtime.{Graph, Failure}
  def apply(g, f), do: if(Failure.excludes_edge?(f), do: Graph.exclude(g, f.edge_id), else: g)
end

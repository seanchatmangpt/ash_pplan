defmodule AshPPlan.FOND.Runtime.Router do
  alias AshPPlan.FOND.Runtime.{Graph, Selector}

  def next(g, c, p), do: g |> Graph.candidates(c) |> Selector.choose(p)

  # First edge whose id has not failed (policy-runtime-r4 routing).
  def route(edges, failed), do: Enum.find(edges, &(not MapSet.member?(failed, &1.id)))
end

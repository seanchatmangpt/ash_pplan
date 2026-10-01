defmodule AshPPlan.FOND.Runtime.Planner do
  @moduledoc false
  def plan(edges, failed),
    do: edges |> Enum.reject(&MapSet.member?(failed, &1.id)) |> Enum.map(& &1.id)
end

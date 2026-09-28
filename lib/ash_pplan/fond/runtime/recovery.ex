defmodule AshPPlan.FOND.Runtime.Recovery do
 @moduledoc false
 def next(edges,failed),do: Enum.find(edges,fn e->not MapSet.member?(failed,e.id) end)
end

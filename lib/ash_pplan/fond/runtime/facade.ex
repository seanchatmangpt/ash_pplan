defmodule AshPPlan.FOND.Runtime.Facade do
 @moduledoc false
 def next_edge(edges,failed),do: AshPPlan.FOND.Runtime.Dispatch.next(edges,failed)
 def exclude(failed,id),do: MapSet.put(failed,id)
end

defmodule AshPPlan.FOND.Runtime.EdgeSet do
 @moduledoc false
 def ids(edges),do: MapSet.new(edges,& &1.id)
 def remove(s,id),do: MapSet.delete(s,id)
end

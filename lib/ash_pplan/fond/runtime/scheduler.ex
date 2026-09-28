defmodule AshPPlan.FOND.Runtime.Scheduler do
 @moduledoc false
 def order(xs),do: Enum.sort_by(xs,&{Map.get(&1,:priority,0),Map.get(&1,:id)})
end

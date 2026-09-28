defmodule AshPPlan.FOND.Runtime.Fallback do
 @moduledoc false
 def next(ps,failed),do: Enum.find(ps,&(not MapSet.member?(failed,Map.get(&1,:id))))
end

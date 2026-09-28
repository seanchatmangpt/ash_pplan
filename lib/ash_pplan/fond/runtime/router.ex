defmodule AshPPlan.FOND.Runtime.Router do
 @moduledoc false
 def route(edges,failed),do: Enum.find(edges,&(not MapSet.member?(failed,&1.id)))
end

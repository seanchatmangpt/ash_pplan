defmodule AshPPlan.FOND.Runtime.RecoveryPlan do
 @moduledoc false
 def build(edges,failed),do: Enum.reject(edges,&MapSet.member?(failed,&1.id))
end

defmodule AshPPlan.FOND.Runtime.Reconciler do
 @moduledoc false
 def reconcile(health,ids),do: Map.new(ids,&{&1,Map.get(health,&1,%AshPPlan.FOND.Runtime.Health{})})
end

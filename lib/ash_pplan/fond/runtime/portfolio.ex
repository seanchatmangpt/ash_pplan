defmodule AshPPlan.FOND.Runtime.Portfolio do
 @moduledoc false
 def rank(xs),do: Enum.sort_by(xs,&{-Map.get(&1,:score,0),Map.get(&1,:id)})
end

defmodule AshPPlan.FOND.Runtime.Exclusion do
 @moduledoc false
 defstruct edges: MapSet.new()
 def add(%__MODULE__{edges:s}=x,e),do: %{x|edges:MapSet.put(s,e)}
end

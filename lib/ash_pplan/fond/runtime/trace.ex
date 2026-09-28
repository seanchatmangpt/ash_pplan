defmodule AshPPlan.FOND.Runtime.Trace do
 @moduledoc false
 defstruct events: []
 def append(%__MODULE__{events:e}=t,x),do: %{t|events:e++[x]}
end

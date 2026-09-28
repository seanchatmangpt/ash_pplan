defmodule AshPPlan.FOND.Runtime.Trace do
 defstruct events: []
 def add(t,e), do: %{t|events:[e|t.events]}
 def chronological(t), do: Enum.reverse(t.events)
end
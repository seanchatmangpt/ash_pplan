defmodule AshPPlan.FOND.Supervision.State do
  defstruct [:domain,:initial,:selected,candidates:[],excluded:MapSet.new(),refused:[],history:[]]
  def record(%__MODULE__{}=s,e), do: %{s|history:[e|s.history]}
end

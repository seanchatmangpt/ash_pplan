defmodule AshPPlan.FOND.Supervision.Trace do
  def append(trace, event), do: trace ++ [event]
  def selected(trace), do: Enum.filter(trace, &(&1.type == :selected))
  def refusals(trace), do: Enum.filter(trace, &(&1.type == :refused))
end

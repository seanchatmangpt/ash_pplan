defmodule AshPPlan.FOND.Supervision.Cost do
  def bounded(v, max) when is_number(v) and v >= 0 and v <= max, do: {:ok, v}
  def bounded(v, max), do: {:error, {:cost_out_of_bounds, v, max}}
end

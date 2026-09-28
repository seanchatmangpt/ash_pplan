defmodule AshPPlan.FOND.Supervision.ProviderHealth do
  defstruct failures: %{}
  def fail(%__MODULE__{}=h,id), do: %{h|failures:Map.update(h.failures,id,1,&(&1+1))}
  def healthy?(%__MODULE__{}=h,id,limit \\ 3), do: Map.get(h.failures,id,0)<limit
  def reset(%__MODULE__{}=h,id), do: %{h|failures:Map.delete(h.failures,id)}
end

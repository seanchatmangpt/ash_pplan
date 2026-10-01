defmodule AshPPlan.FOND.Runtime.Edge do
  @enforce_keys [:id, :capability, :provider]
  defstruct [:id, :capability, :provider, cost: 1, metadata: %{}]
  def new(a), do: struct!(__MODULE__, a)
  def eligible?(%__MODULE__{id: i, capability: c}, r, x), do: c == r and not MapSet.member?(x, i)
end

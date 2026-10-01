defmodule AshPPlan.FOND.Supervision.Candidate do
  @enforce_keys [:id, :policy, :semantics]
  defstruct [:id, :policy, :semantics, cost: 0, provider: nil, metadata: %{}]
  def new(attrs) when is_map(attrs), do: struct!(__MODULE__, attrs)
  def stable_key(%__MODULE__{} = c), do: {rank(c.semantics), c.cost, c.id}
  defp rank(:strong), do: 0
  defp rank(:strong_cyclic), do: 1
  defp rank(_), do: 2
end

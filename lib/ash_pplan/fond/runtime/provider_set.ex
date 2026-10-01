defmodule AshPPlan.FOND.Runtime.ProviderSet do
  @moduledoc false
  def eligible(ps, c), do: Enum.filter(ps, &(c in Map.get(&1, :capabilities, [])))
end

defmodule AshPPlan.FOND.Runtime.ProviderSpec do
  @enforce_keys [:id, :module]
  defstruct [:id, :module, config: nil, capabilities: [], priority: 100]
  def supports?(s, c), do: c in s.capabilities
end

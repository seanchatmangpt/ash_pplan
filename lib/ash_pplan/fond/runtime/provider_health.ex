defmodule AshPPlan.FOND.Runtime.ProviderHealth do
  @moduledoc false
  def usable?(%{status: s}), do: s in [:healthy, :unknown]
  def usable?(_), do: false
end

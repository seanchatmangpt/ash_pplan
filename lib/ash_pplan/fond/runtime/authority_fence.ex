defmodule AshPPlan.FOND.Runtime.AuthorityFence do
  @moduledoc false
  def admit(%{authority: a}) when a in [nil, :none, false], do: :ok
  def admit(_), do: {:error, :authority_bearing_policy}
end

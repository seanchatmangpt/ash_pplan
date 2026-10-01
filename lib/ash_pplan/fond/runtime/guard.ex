defmodule AshPPlan.FOND.Runtime.Guard do
  @moduledoc false
  def admit(%{status: s}) when s in [:ready, :recovering], do: :ok
  def admit(_), do: {:error, :terminal_state}
end

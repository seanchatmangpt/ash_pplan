defmodule AshPPlan.FOND.Runtime.AttemptBudget do
  @moduledoc false
  def consume(%{attempts: a} = b) when a > 0, do: {:ok, %{b | attempts: a - 1}}
  def consume(_), do: {:error, :exhausted}
end

defmodule AshPPlan.FOND.Runtime.Health do
  defstruct status: :unknown, failures: 0, last_error: nil
  def success(_), do: %__MODULE__{status: :healthy}
  def failure(h, r), do: %{h | status: :degraded, failures: h.failures + 1, last_error: r}
  def available?(h), do: h.status != :open
end

defmodule AshPPlan.FOND.Runtime.Policy do
  defstruct max_attempts: 3, timeout_ms: 5_000, strategy: :priority
  def new(opts \\ []), do: struct!(__MODULE__, Map.new(opts))
  def attempt_allowed?(%__MODULE__{max_attempts: n}, a), do: a < n
end

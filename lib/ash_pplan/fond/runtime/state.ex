defmodule AshPPlan.FOND.Runtime.State do
  defstruct [:capability, :input, :result, status: :ready, attempts: 0, failures: [], trace: nil]
  def ready(c, i), do: %__MODULE__{capability: c, input: i, trace: %AshPPlan.FOND.Runtime.Trace{}}
  def transition(s, :dispatch), do: %{s | status: :running}
  def transition(s, {:succeed, r}), do: %{s | status: :succeeded, result: r}
  def transition(s, {:fail, f}), do: %{s | status: :recovering, failures: [f | s.failures]}
  def transition(s, :exhaust), do: %{s | status: :exhausted}
end

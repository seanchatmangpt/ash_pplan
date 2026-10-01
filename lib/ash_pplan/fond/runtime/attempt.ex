defmodule AshPPlan.FOND.Runtime.Attempt do
  defstruct [:edge_id, :provider, :started_at, :finished_at, :outcome]

  def start(e),
    do: %__MODULE__{edge_id: e.id, provider: e.provider, started_at: System.monotonic_time()}

  def finish(a, o), do: %{a | finished_at: System.monotonic_time(), outcome: o}
end

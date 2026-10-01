defmodule AshPPlan.FOND.Runtime.Scheduler do
  def due(xs, now \\ System.monotonic_time(:millisecond)),
    do: Enum.filter(xs, &(&1.due_at <= now))

  def order(xs), do: Enum.sort_by(xs, &{&1.due_at, Map.get(&1, :priority, 100)})
end

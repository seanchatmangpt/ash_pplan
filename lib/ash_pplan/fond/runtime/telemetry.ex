defmodule AshPPlan.FOND.Runtime.Telemetry do
 def event(id,type,attrs \\ %{}), do: %{run_id:id,type:type,attrs:attrs,at:System.monotonic_time()}
end
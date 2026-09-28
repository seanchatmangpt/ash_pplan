defmodule AshPPlan.FOND.Runtime.Telemetry do
 @moduledoc false
 def event(name,meta \\ %{}),do: %{name:name,metadata:meta,at:System.system_time(:millisecond)}
end

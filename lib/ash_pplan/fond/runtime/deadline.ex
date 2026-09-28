defmodule AshPPlan.FOND.Runtime.Deadline do
 @moduledoc false
 def expired?(d,now \\ System.monotonic_time(:millisecond)),do: now>=d
end

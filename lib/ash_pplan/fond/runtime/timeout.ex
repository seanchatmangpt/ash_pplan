defmodule AshPPlan.FOND.Runtime.Timeout do
 @moduledoc false
 def deadline(now,ms),do: now+ms
 def remaining(d,now),do: max(d-now,0)
end

defmodule AshPPlan.FOND.Runtime.Backoff do
 @moduledoc false
 def delay(n,base \\ 10,cap \\ 5_000),do: min(cap,trunc(base*:math.pow(2,max(n-1,0))))
end

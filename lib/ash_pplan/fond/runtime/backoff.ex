defmodule AshPPlan.FOND.Runtime.Backoff do
 def delay(a,opts \\ []), do: min(Keyword.get(opts,:cap,2_000),trunc(Keyword.get(opts,:base,25)*:math.pow(2,max(a-1,0))))
end
defmodule AshPPlan.FOND.Runtime.Failure do
 defstruct [:edge_id,:class,:reason,:attempt]
 def new(e,c,r,a), do: %__MODULE__{edge_id:e,class:c,reason:r,attempt:a}
 def excludes_edge?(%__MODULE__{class:c}), do: c in [:retryable,:terminal,:refused]
end
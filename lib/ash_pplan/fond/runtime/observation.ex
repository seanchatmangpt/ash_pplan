defmodule AshPPlan.FOND.Runtime.Observation do
 @moduledoc false
 defstruct [:edge,:provider,:result,:at]
 def success?(%__MODULE__{result:{:ok,_}}),do: true
 def success?(_),do: false
end

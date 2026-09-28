defmodule AshPPlan.FOND.Runtime.Policy do
 @moduledoc false
 defstruct [:id,:mapping,:mode,:authority]
 def powerless?(%__MODULE__{authority:a}),do: a in [nil,:none,false]
end

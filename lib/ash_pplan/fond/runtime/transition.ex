defmodule AshPPlan.FOND.Runtime.Transition do
 @moduledoc false
 def apply(s,{:fail,e}),do: %{s|failed:MapSet.put(s.failed,e),attempts:s.attempts+1,status: :recovering}
 def apply(s,{:succeed,e}),do: %{s|edge:e,status: :succeeded}
end

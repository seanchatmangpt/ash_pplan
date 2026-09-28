defmodule AshPPlan.FOND.Runtime.EventLog do
 @moduledoc false
 def append(log,e),do: log++[e]
 def for_run(log,id),do: Enum.filter(log,&(&1.run_id==id))
end

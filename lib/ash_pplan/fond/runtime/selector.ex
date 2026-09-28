defmodule AshPPlan.FOND.Runtime.Selector do
 def choose([],_), do: {:error,:exhausted}
 def choose(es,%{strategy: :priority}), do: {:ok,Enum.min_by(es,& &1.cost)}
 def choose(es,%{strategy: :stable}), do: {:ok,Enum.min_by(es,&to_string(&1.id))}
 def choose([e|_],_), do: {:ok,e}
end
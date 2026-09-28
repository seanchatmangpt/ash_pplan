defmodule AshPPlan.FOND.Runtime.Transition do
 @allowed %{ready:[:running],running:[:succeeded,:recovering,:exhausted],recovering:[:running,:exhausted],succeeded:[],exhausted:[]}
 def allowed?(a,b), do: b in Map.get(@allowed,a,[])
 def admit(a,b), do: if(allowed?(a,b),do::ok,else:{:error,{:invalid_transition,a,b}})
end
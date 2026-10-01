defmodule AshPPlan.FOND.Runtime.Router do
 alias AshPPlan.FOND.Runtime.{Graph,Selector}
 def next(g,c,p), do: g|>Graph.candidates(c)|>Selector.choose(p)
end
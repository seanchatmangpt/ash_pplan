defmodule AshPPlan.FOND.Runtime do
 alias AshPPlan.FOND.Runtime.{Graph,State,Policy,Engine,Receipt,RunId}
 def run(edges,cap,input,opts \\ []) do
  id=RunId.new(to_string(cap)); g=Graph.new(edges); s=State.ready(cap,input); p=Policy.new(opts)
  case Engine.run(g,s,p) do
   {:ok,s,g}->{:ok,s.result,Receipt.from_state(id,s),g}
   {:error,s,g}->{:error,s.status,Receipt.from_state(id,s),g}
  end
 end
end
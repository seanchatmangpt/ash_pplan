defmodule AshPPlan.FOND.Runtime.EngineTest do
 use ExUnit.Case, async: true
 alias AshPPlan.FOND.Runtime.{Edge,Graph,State,Policy,Engine}
 defmodule Bad do def dispatch(_,_,_), do: {:error,:unavailable} end
 defmodule Good do def dispatch(input,_,_), do: {:ok,{:served,input}} end
 test "FOND routes around failed edge" do
  edges=[Edge.new(%{id: :bad,capability: :plan,provider: Bad,cost: 1}),Edge.new(%{id: :good,capability: :plan,provider: Good,cost: 2})]
  assert {:ok,%{result: {:served,:work},attempts: 2},g}=Engine.run(Graph.new(edges),State.ready(:plan,:work),Policy.new())
  assert MapSet.member?(g.excluded,:bad)
 end
end
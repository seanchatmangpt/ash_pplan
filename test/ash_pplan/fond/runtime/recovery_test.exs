defmodule AshPPlan.FOND.Runtime.RecoveryTest do
 use ExUnit.Case, async: true
 alias AshPPlan.FOND.Runtime.{Edge,Graph,Failure,Recovery}
 test "failure removes only its edge" do
  es=for id<-[:a,:b],do:Edge.new(%{id:id,capability: :x,provider:nil}); g=Graph.new(es)
  g=Recovery.apply(g,Failure.new(:a,:retryable,:timeout,1))
  assert Enum.map(Graph.candidates(g,:x),& &1.id)==[:b]
 end
end
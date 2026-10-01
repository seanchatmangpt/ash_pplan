defmodule AshPPlan.FOND.Supervision.EngineTest do
  use ExUnit.Case, async: true
  alias AshPPlan.FOND; alias AshPPlan.FOND.Supervision.{Candidate,Engine}
  test "selection emits receipt" do
    {:ok,d}=FOND.new(%{a=>%{go=>[:g]}},[:g]); c=Candidate.new(%{id: :x,policy:%{a=>go},semantics: :strong}); {r,s}=Engine.new(d,a,[c]) |> Engine.select(); assert {:ok,^c,%{event: :policy_selected}}=r; assert s.selected.id==:x
  end
end

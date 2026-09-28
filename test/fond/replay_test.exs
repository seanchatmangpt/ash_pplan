defmodule AshPPlan.FOND.ReplayTest do
 use ExUnit.Case,async:true
 alias AshPPlan.FOND
 test "seed replays" do
  {:ok,d}=FOND.new(%{a:%{go:[:a,:g]},g:%{}},[:g]);p=%{a: :go}
  assert AshPPlan.FOND.Replay.trace(d,p,:a,seed:{7,11,13})==AshPPlan.FOND.Replay.trace(d,p,:a,seed:{7,11,13})
 end
end

defmodule AshPPlan.FOND.Supervision.RecoveryTest do
  use ExUnit.Case, async: true
  alias AshPPlan.FOND.Supervision.Recovery
  test "edge failure excludes candidate" do
    {:reselect,set}=Recovery.route(MapSet.new(),:a,:timeout); assert MapSet.member?(set,:a)
  end
end

defmodule AshPPlan.FOND.Runtime.ReconcilerTest do
 use ExUnit.Case, async: true
 alias AshPPlan.FOND.Runtime.Reconciler
 test "computes start and stop sets" do
  r=Reconciler.reconcile([%{id: :a}],[%{id: :b}]); assert r.start==MapSet.new([:a]); assert r.stop==MapSet.new([:b])
 end
end
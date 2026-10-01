defmodule AshPPlan.FOND.Runtime.BackoffTest do
 use ExUnit.Case, async: true
 alias AshPPlan.FOND.Runtime.Backoff
 test "bounded exponential delay" do assert Backoff.delay(1,base:10)==10; assert Backoff.delay(10,base:10,cap:100)==100 end
end
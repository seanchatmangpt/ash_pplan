defmodule AshPPlan.FOND.Runtime.LeaseTest do
 use ExUnit.Case, async: true
 alias AshPPlan.FOND.Runtime.Lease
 test "positive ttl is initially valid", do: assert Lease.valid?(Lease.new(self(),1_000))
end
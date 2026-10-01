defmodule AshPPlan.PolicyClosure.LeaseTest do
 use ExUnit.Case, async: true
 alias AshPPlan.PolicyClosure.Lease
 test "expires logically", do: refute Lease.valid?(3,2)
end

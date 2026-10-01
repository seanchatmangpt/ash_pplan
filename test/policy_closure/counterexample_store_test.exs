defmodule AshPPlan.PolicyClosure.CounterexampleStoreTest do
  use ExUnit.Case, async: true
  alias AshPPlan.PolicyClosure.CounterexampleStore

  test "subject bound",
    do: assert(CounterexampleStore.put("s", :liveness, :cycle).subject_id == "s")
end

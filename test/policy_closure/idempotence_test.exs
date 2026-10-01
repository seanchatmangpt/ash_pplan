defmodule AshPPlan.PolicyClosure.IdempotenceTest do
  use ExUnit.Case, async: true
  alias AshPPlan.PolicyClosure.Idempotence

  test "same operation same key",
    do: assert(Idempotence.key("s", :plan) == Idempotence.key("s", :plan))
end

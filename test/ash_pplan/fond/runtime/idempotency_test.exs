defmodule AshPPlan.FOND.Runtime.IdempotencyTest do
  use ExUnit.Case, async: true
  alias AshPPlan.FOND.Runtime.Idempotency

  test "same admitted input has stable key" do
    assert Idempotency.key(:x, %{a: 1}) == Idempotency.key(:x, %{a: 1})
  end
end

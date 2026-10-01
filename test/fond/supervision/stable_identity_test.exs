defmodule AshPPlan.FOND.Supervision.StableIdentityTest do
  use ExUnit.Case, async: true
  alias AshPPlan.FOND.Supervision.StableIdentity
  test "identity is deterministic and semantics bound" do
    a=StableIdentity.of(%{s: :a},:strong); assert a==StableIdentity.of(%{s: :a},:strong); refute a==StableIdentity.of(%{s: :a},:strong_cyclic)
  end
end

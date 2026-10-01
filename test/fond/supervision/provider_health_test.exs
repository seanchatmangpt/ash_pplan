defmodule AshPPlan.FOND.Supervision.ProviderHealthTest do
  use ExUnit.Case, async: true
  alias AshPPlan.FOND.Supervision.ProviderHealth

  test "opens after bounded failures" do
    h = %ProviderHealth{} |> ProviderHealth.fail(:p) |> ProviderHealth.fail(:p)
    assert ProviderHealth.healthy?(h, :p, 3)
    refute ProviderHealth.healthy?(ProviderHealth.fail(h, :p), :p, 3)
  end
end

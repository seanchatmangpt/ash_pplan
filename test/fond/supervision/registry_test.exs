defmodule AshPPlan.FOND.Supervision.RegistryTest do
  use ExUnit.Case, async: true
  alias AshPPlan.FOND.Supervision.Registry

  test "registry is deterministic" do
    {:ok, p} = Registry.start_link()
    :ok = Registry.put(p, :b, B)
    :ok = Registry.put(p, :a, A)
    assert Registry.list(p) == [a: A, b: B]
  end
end

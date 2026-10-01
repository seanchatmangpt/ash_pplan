defmodule AshPPlan.FOND.Runtime.SelectorTest do
  use ExUnit.Case, async: true
  alias AshPPlan.FOND.Runtime.{Edge, Selector, Policy}

  test "priority chooses lowest cost" do
    a = Edge.new(%{id: :a, capability: :x, provider: nil, cost: 9})
    b = Edge.new(%{id: :b, capability: :x, provider: nil, cost: 1})
    assert {:ok, ^b} = Selector.choose([a, b], Policy.new())
  end
end

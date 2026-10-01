defmodule AshPPlan.FOND.Runtime.GraphTest do
  use ExUnit.Case, async: true
  alias AshPPlan.FOND.Runtime.{Edge, Graph}

  test "failed edge is excluded without failing graph" do
    e = Edge.new(%{id: :a, capability: :plan, provider: __MODULE__})
    g = Graph.new([e]) |> Graph.exclude(:a)
    assert Graph.exhausted?(g, :plan)
  end
end

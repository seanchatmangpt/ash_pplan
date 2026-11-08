defmodule AshPPlan.POWL.ChoiceGraphTest do
  use ExUnit.Case, async: true

  alias AshPPlan.POWL

  describe "gamma choice-graph verifier rules" do
    test "child self-loop is refused" do
      model =
        POWL.choice_graph("g1", [POWL.activity("a"), POWL.activity("b")], [
          {:start, {:child, 0}},
          {{:child, 0}, {:child, 0}},
          {{:child, 1}, :end}
        ])

      assert {:error, %{reason: :cyclic_choice_graph, block: %{block_id: "g1"}}} =
               POWL.Verifier.verify(model)
    end

    test "child with no start in-edge is refused as unreachable" do
      model =
        POWL.choice_graph("g2", [POWL.activity("a"), POWL.activity("b")], [
          {:start, {:child, 0}},
          {{:child, 0}, :end},
          {{:child, 1}, :end}
        ])

      assert {:error, %{reason: :unreachable_choice_child, block: %{child_index: 1}}} =
               POWL.Verifier.verify(model)
    end

    test "well-formed acyclic gamma verifies and round-trips through normalize" do
      model =
        POWL.choice_graph("g3", [POWL.activity("a"), POWL.activity("b")], [
          {:start, {:child, 0}},
          {:start, {:child, 1}},
          {{:child, 0}, :end},
          {{:child, 1}, :end}
        ])

      assert POWL.Verifier.verify(model) == :ok
      assert {:ok, ^model} = POWL.normalize(model)
    end
  end
end

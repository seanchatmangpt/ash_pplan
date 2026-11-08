defmodule AshPPlan.POWL.VerifierTest do
  use ExUnit.Case, async: true

  alias AshPPlan.POWL

  describe "sound models verify" do
    test "sequence of choices" do
      model =
        POWL.sequence("s1", [
          POWL.choice("c1", [POWL.activity("a"), POWL.activity("b")]),
          POWL.choice("c2", [POWL.activity("c"), POWL.activity("d")])
        ])

      assert POWL.Verifier.verify(model) == :ok
    end

    test "choice of sequences" do
      model =
        POWL.choice("c1", [
          POWL.sequence("s1", [POWL.activity("a"), POWL.activity("b")]),
          POWL.sequence("s2", [POWL.activity("c"), POWL.activity("d")])
        ])

      assert POWL.Verifier.verify(model) == :ok
    end

    test "loop composition" do
      model =
        POWL.loop("l1", POWL.activity("body"), POWL.activity("redo"))

      assert POWL.Verifier.verify(model) == :ok
    end

    test "partial order with a sequence of choice blocks (comparable flows)" do
      a = POWL.activity("a")
      inner = POWL.choice("inner", [POWL.activity("b1"), POWL.activity("b2")])
      d = POWL.activity("d")

      model = POWL.partial_order("po", [a, inner, d], [{"a", "inner"}, {"inner", "d"}])

      assert POWL.Verifier.verify(model) == :ok
    end

    test "leaf-only model" do
      model = POWL.partial_order("po", [POWL.activity("a"), POWL.activity("b")], [])
      assert POWL.Verifier.verify(model) == :ok
    end
  end

  describe "unsound models are refused with the block named" do
    test "PT-handle: choice child with two incomparable predecessors" do
      a = POWL.activity("a")
      b = POWL.activity("b")
      c = POWL.choice("c", [POWL.activity("c1"), POWL.activity("c2")])

      model = POWL.partial_order("po", [a, b, c], [{"a", "c"}, {"b", "c"}])

      assert {:error, %{reason: :non_separable_block, block: block}} =
               POWL.Verifier.verify(model)

      assert block.cause == :pt_handle_choice_interior
      assert block.side == :in
      assert block.node == "c"
    end

    test "PT-handle: choice child with two incomparable successors" do
      c = POWL.choice("c", [POWL.activity("c1"), POWL.activity("c2")])
      d = POWL.activity("d")
      e = POWL.activity("e")

      model = POWL.partial_order("po", [c, d, e], [{"c", "d"}, {"c", "e"}])

      assert {:error, %{reason: :non_separable_block, block: block}} =
               POWL.Verifier.verify(model)

      assert block.cause == :pt_handle_choice_interior
      assert block.side == :out
    end

    test "order cycle is refused" do
      a = POWL.activity("a")
      b = POWL.activity("b")

      model = POWL.partial_order("po", [a, b], [{"a", "b"}, {"b", "a"}])

      assert {:error, %{reason: :non_separable_block, block: %{cause: :order_cycle}}} =
               POWL.Verifier.verify(model)
    end

    test "unknown order edge is refused" do
      a = POWL.activity("a")

      model = POWL.partial_order("po", [a], [{"a", "ghost"}])

      assert {:error, %{reason: :non_separable_block, block: %{cause: :unknown_order_edge}}} =
               POWL.Verifier.verify(model)
    end

    test "unsupported shape is refused" do
      assert {:error, %{reason: :unsupported_powl_shape}} =
               POWL.Verifier.verify("not a model")
    end
  end

  describe "normalization" do
    test "accepts a candidate map wrapping a catalog plan" do
      plan = AshPPlan.plans() |> List.first()

      assert {:ok, %POWL.Node{operator: :partial_order}} =
               POWL.normalize(%{formalism: :powl, plan: plan})
    end

    test "accepts a raw catalog plan map" do
      plan = AshPPlan.plans() |> List.first()
      assert {:ok, %POWL.Node{}} = POWL.normalize(plan)
    end
  end

  describe "property: every plan-catalog model verifies" do
    test "all catalog plans are sound" do
      for plan <- AshPPlan.plans() do
        assert POWL.Verifier.verify(plan) == :ok,
               "catalog plan #{plan.iri} failed POWL verification"
      end
    end
  end
end

# SPDX-License-Identifier: MIT
#
# Van der Aalst conformance court - Tokyo depeg lifecycle.
#
# Required lifecycle (Petri net):
#   RiskPreflight -> CollateralCheck -> SanctionsScreen -> Execution
#
# Anti-vacuity: the aligner must refuse the empty model and the permissive
# model outright, so a court that always passes is structurally impossible.

defmodule TokyoDepeg.ConformanceAlignmentTest do
  use ExUnit.Case, async: true

  alias AshPplan.TokyoDepeg.Alignment

  @lifecycle ["RiskPreflight", "CollateralCheck", "SanctionsScreen", "Execution"]

  describe "honest trace" do
    test "aligns at cost 0 and is judged conformant" do
      assert {:ok, model} = Alignment.lifecycle()
      assert {:ok, %Alignment.Result{cost: 0, moves: moves}} = Alignment.align(model, @lifecycle)

      assert moves == [
               {:sync, :t_preflight, "RiskPreflight"},
               {:sync, :t_collateral, "CollateralCheck"},
               {:sync, :t_sanctions, "SanctionsScreen"},
               {:sync, :t_execution, "Execution"}
             ]

      assert {:conformant, _} = Alignment.judge(model, @lifecycle)
    end
  end

  describe "mutants (cost > 0 and REFUSED)" do
    test "sanctions-skip omits SanctionsScreen -> lifecycle_sanctions_omitted" do
      assert {:ok, model} = Alignment.lifecycle()
      trace = ["RiskPreflight", "CollateralCheck", "Execution"]

      assert {:ok, %Alignment.Result{cost: cost, moves: moves}} = Alignment.align(model, trace)
      assert cost > 0
      assert {:model_move, :t_sanctions} in moves or {:log_move, "Execution"} in moves
      assert {:refused, :lifecycle_sanctions_omitted} = Alignment.judge(model, trace)
    end

    test "reordered stages swap CollateralCheck and SanctionsScreen -> lifecycle_order_violation" do
      assert {:ok, model} = Alignment.lifecycle()
      trace = ["RiskPreflight", "SanctionsScreen", "CollateralCheck", "Execution"]

      assert {:ok, %Alignment.Result{cost: cost}} = Alignment.align(model, trace)
      assert cost > 0
      assert {:refused, :lifecycle_order_violation} = Alignment.judge(model, trace)
    end
  end

  describe "extra execution mutant" do
    test "unmodelled second Execution -> cost > 0, lifecycle_unmodelled_activity" do
      assert {:ok, model} = Alignment.lifecycle()
      trace = @lifecycle ++ ["Execution"]

      assert {:ok, %Alignment.Result{cost: cost, moves: moves}} = Alignment.align(model, trace)
      assert cost > 0
      assert {:log_move, "Execution"} in moves
      assert {:refused, :lifecycle_unmodelled_activity} = Alignment.judge(model, trace)
    end
  end

  describe "anti-vacuity" do
    test "aligner refuses the empty model" do
      assert {:refused, :empty_model} =
               Alignment.build(transitions: [], places: [], initial: :a, final: :b)

      assert {:refused, :empty_model} = Alignment.align(nil, @lifecycle)

      zero_transition_model = %Alignment.Model{
        places: MapSet.new([:p]),
        transitions: %{},
        initial: :p,
        final: :p
      }

      assert {:refused, :empty_model} = Alignment.align(zero_transition_model, @lifecycle)
    end

    test "aligner refuses the permissive model outright" do
      permissive = Alignment.permissive()

      assert {:ok, %Alignment.Result{cost: 0}} =
               Alignment.align(permissive, ["RiskPreflight", "CollateralCheck", "Execution"])

      assert {:refused, :permissive_model} = Alignment.judge(permissive, @lifecycle)
    end

    test "dangling transitions are refused at build time" do
      assert {:refused, :empty_model} =
               Alignment.build(
                 places: [:a, :b],
                 initial: :a,
                 final: :b,
                 transitions: [{:t, "X", {:a, :ghost}}]
               )
    end
  end
end

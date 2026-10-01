defmodule AshPPlan.SA2A.RefusalTest do
  use ExUnit.Case, async: true

  alias AshPPlan.SA2A.Refusal

  test "owner adapter refusals carry no authority" do
    assert %{code: :planner_refused, authority: :none} =
             Refusal.new(:planner_refused, :no_policy)
  end

  # AshA2A.Semantic.Refusal maps these codes on the consumer side; a change here
  # is a consumer contract change.
  test "refusal codes are the closed owner-side set" do
    assert Enum.sort(Refusal.codes()) ==
             Enum.sort([
               :missing_domain,
               :missing_initial,
               :missing_plan_iri,
               :missing_subject,
               :plan_not_found,
               :planner_refused,
               :unsupported_formalism
             ])
  end

  test "consumer-side consequence codes are not owner-side codes" do
    for code <- [:unknown_castle_edge_donor, :effect_claim_not_found] do
      assert_raise FunctionClauseError, fn -> Refusal.new(code) end
    end
  end
end

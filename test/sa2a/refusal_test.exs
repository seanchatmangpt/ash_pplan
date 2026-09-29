defmodule AshPPlan.SA2A.RefusalTest do
  use ExUnit.Case, async: true

  alias AshPPlan.SA2A.Refusal

  test "owner adapter refusals carry no authority" do
    assert %{code: :planner_refused, authority: :none} =
             Refusal.new(:planner_refused, :no_policy)
  end
end

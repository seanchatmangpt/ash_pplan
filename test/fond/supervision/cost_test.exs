defmodule AshPPlan.FOND.Supervision.CostTest do
  use ExUnit.Case, async: true
  alias AshPPlan.FOND.Supervision.Cost

  test "cost is bounded" do
    assert {:ok, 2} = Cost.bounded(2, 3)
    assert {:error, _} = Cost.bounded(4, 3)
  end
end

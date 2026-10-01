defmodule AshPPlan.PolicyClosure.PolicyPortfolioTest do
  use ExUnit.Case, async: true
  alias AshPPlan.PolicyClosure.PolicyPortfolio

  test "deterministic rank",
    do:
      assert(
        Enum.map(PolicyPortfolio.rank([%{id: :b, cost: 2}, %{id: :a, cost: 1}]), & &1.id) == [
          :a,
          :b
        ]
      )
end

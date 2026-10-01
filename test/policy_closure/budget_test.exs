defmodule AshPPlan.PolicyClosure.BudgetTest do
  use ExUnit.Case, async: true
  alias AshPPlan.PolicyClosure.Budget
  test "bounded", do: assert({:error, :budget_exceeded} = Budget.admit(2, 1))
end

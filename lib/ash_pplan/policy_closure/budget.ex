defmodule AshPPlan.PolicyClosure.Budget do
  def admit(used, limit) when used <= limit, do: :ok
  def admit(_, _), do: {:error, :budget_exceeded}
end

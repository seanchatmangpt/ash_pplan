defmodule AshPPlan.FOND.Supervision.Revalidation do
  alias AshPPlan.FOND.Supervision.Validator
  def check(domain,initial,candidate), do: Validator.validate(domain,initial,candidate)
end

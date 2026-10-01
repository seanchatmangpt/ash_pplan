defmodule AshPPlan.PolicyClosure.AuthorityCeilingTest do
  use ExUnit.Case, async: true
  alias AshPPlan.PolicyClosure.AuthorityCeiling
  test "refuses do", do: assert({:error, :authority_ceiling} = AuthorityCeiling.admit(:do))
end

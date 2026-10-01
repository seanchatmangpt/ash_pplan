defmodule AshPPlan.PolicyClosure.LivenessGuardTest do
  use ExUnit.Case, async: true
  alias AshPPlan.PolicyClosure.LivenessGuard
  test "fails closed", do: assert({:error, :liveness_unproven} = LivenessGuard.admit(:unknown))
end

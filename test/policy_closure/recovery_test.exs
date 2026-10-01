defmodule AshPPlan.PolicyClosure.RecoveryTest do
  use ExUnit.Case, async: true
  alias AshPPlan.PolicyClosure.Recovery
  test "typed routes", do: assert(Recovery.route(:stale_subject) == :rebind)
end

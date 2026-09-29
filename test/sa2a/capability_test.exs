defmodule AshPPlan.SA2A.CapabilityTest do
  use ExUnit.Case, async: true

  alias AshPPlan.SA2A.Capability

  test "planner capability is candidate-only and has no DO authority" do
    assert Capability.supports?(:fond)
    assert Capability.supports?(:powl)
    refute Capability.supports?(:hddl)

    assert %{
             authority: :none,
             standing: :candidate,
             select: true,
             construct: true,
             do: false
           } = Capability.descriptor(:fond)
  end
end

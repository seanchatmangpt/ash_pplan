defmodule AshPPlan.FOND.ResearchWave11Test do
  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.FOND.PolicySwitch

  test "wave 11 selects strong before strong-cyclic when possible" do
    {:ok, domain} = FOND.new(%{pending: %{go: [:done]}, done: %{}}, [:done])

    assert {:ok, selected} = PolicySwitch.select(domain, :pending)
    assert selected.mode == :strong
    assert selected.policy == %{pending: :go}
  end
end

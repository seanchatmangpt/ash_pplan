defmodule AshPPlan.FONDPolicySwitchTest do
  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.FOND.PolicySwitch

  test "prefers strong when a strong policy exists" do
    {:ok, domain} = FOND.new(%{pending: %{finish: [:done]}, done: %{}}, [:done])

    assert {:ok, selected} = PolicySwitch.select(domain, :pending)
    assert selected.mode == :strong
    assert selected.policy == %{pending: :finish}
    assert selected.attempts == []
  end

  test "falls back to strong cyclic when strong is unsolvable" do
    {:ok, domain} =
      FOND.new(%{pending: %{attempt: [:pending, :done]}, done: %{}}, [:done])

    assert {:ok, selected} = PolicySwitch.select(domain, :pending)
    assert selected.mode == :strong_cyclic
    assert [{:strong, {:unsolvable, :strong, _}}] = selected.attempts
  end

  test "returns all typed attempts when no requested mode solves initial" do
    {:ok, domain} = FOND.new(%{pending: %{fail: [:dead]}, dead: %{}, done: %{}}, [:done])

    assert {:error, error} = PolicySwitch.select(domain, :pending)
    assert error.reason == :no_admitted_policy
    assert length(error.attempted_modes) == 2
  end
end

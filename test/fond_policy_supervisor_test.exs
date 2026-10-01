defmodule AshPPlan.FOND.PolicySupervisorTest do
  use ExUnit.Case, async: true
  alias AshPPlan.FOND
  alias AshPPlan.FOND.PolicySupervisor.Offers, as: PolicySupervisor

  test "prefers strong, falls back on provider loss, and fences stale epochs" do
    {:ok, d} = FOND.new(%{start: %{go: [:done]}, done: %{}}, [:done])

    offers = [
      %{
        provider: :cyclic,
        mode: :strong_cyclic,
        policy: %{start: :go},
        cost: 0,
        authority: :none
      },
      %{provider: :strong, mode: :strong, policy: %{start: :go}, cost: 5, authority: :none}
    ]

    {:ok, s} = PolicySupervisor.new(d, :start, offers)
    assert s.provider == :strong
    {:ok, cmd} = PolicySupervisor.next_action(s)
    {:ok, s2} = PolicySupervisor.provider_down(s, :strong)
    assert s2.provider == :cyclic

    assert {:error, {:stale_epoch, 0, 1}} =
             PolicySupervisor.observe(s2, cmd.epoch, cmd.action, :done)
  end

  test "authority-bearing offers are not admissible" do
    {:ok, d} = FOND.new(%{start: %{go: [:done]}, done: %{}}, [:done])

    assert {:error, :no_admissible_policy} =
             PolicySupervisor.new(d, :start, [
               %{provider: :x, policy: %{start: :go}, authority: :do}
             ])
  end
end

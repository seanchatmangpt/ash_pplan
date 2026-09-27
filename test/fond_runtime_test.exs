defmodule AshPPlan.FOND.RuntimeTest do
  use ExUnit.Case, async: true
  alias AshPPlan.FOND
  alias AshPPlan.FOND.{PolicySupervisor, ProviderRegistry, Runtime}

  test "OTP runtime serializes fenced policy and provider observations" do
    {:ok, domain} = FOND.new(%{pending: %{attempt: [:pending, :done]}, done: %{}}, [:done])
    {:ok, policy} = PolicySupervisor.start(domain, :pending)
    registry = ProviderRegistry.new([
      %{id: :primary, capabilities: [:fond], cost: 0},
      %{id: :secondary, capabilities: [:fond], cost: 1}
    ])
    {:ok, pid} = Runtime.start_link(policy: policy, registry: registry, requirements: [:fond])
    assert {:ok, %{policy: %{action: :attempt, epoch: 0}, provider: %{id: :primary}}} = Runtime.intent(pid)
    snapshot = Runtime.snapshot(pid)
    assert {:ok, _} = Runtime.observe_provider_health(pid, snapshot.provider_generation, :primary, false)
    assert {:ok, %{provider: %{id: :secondary}}} = Runtime.intent(pid)
    assert {:ok, _} = Runtime.observe_outcome(pid, 0, :pending)
    assert {:error, {:stale_epoch, 0, 1}} = Runtime.observe_outcome(pid, 0, :done)
  end
end

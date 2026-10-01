defmodule AshPPlan.FOND.SupervisionTest do
  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.FOND.{PolicySupervisor, ProviderRegistry, SupervisionSession}

  defp domain do
    {:ok, domain} =
      FOND.new(%{pending: %{attempt: [:pending, :done]}, done: %{}}, [:done])

    domain
  end

  test "policy supervisor emits powerless fenced intents and advances admitted outcomes" do
    assert {:ok, supervisor} = PolicySupervisor.start(domain(), :pending)

    assert {:ok, %{kind: :fond_action, action: :attempt, epoch: 0}} =
             PolicySupervisor.intent(supervisor)

    assert {:ok, next} = PolicySupervisor.observe(supervisor, 0, :pending)
    assert next.epoch == 1
    assert {:error, {:stale_epoch, 0, 1}} = PolicySupervisor.observe(next, 0, :done)

    assert {:error, {:unadmitted_outcome, :pending, :elsewhere}} =
             PolicySupervisor.observe(next, 1, :elsewhere)
  end

  test "registry routes by capability, health, cost, and stable identity" do
    registry =
      ProviderRegistry.new([
        %{id: :slow, capabilities: [:fond], cost: 5},
        %{id: :cheap, capabilities: [:fond, :retry], cost: 1}
      ])

    assert {:ok, %{id: :cheap}, generation} = ProviderRegistry.select(registry, [:fond])
    assert {:ok, registry} = ProviderRegistry.observe_health(registry, generation, :cheap, false)
    assert {:ok, %{id: :slow}, _} = ProviderRegistry.select(registry, [:fond])

    assert {:error, {:stale_generation, ^generation, _}} =
             ProviderRegistry.observe_health(registry, generation, :slow, false)
  end

  test "session rebinds when the bound provider becomes unhealthy" do
    registry =
      ProviderRegistry.new([
        %{id: :a, capabilities: [:fond], cost: 0},
        %{id: :b, capabilities: [:fond], cost: 1}
      ])

    {:ok, policy} = PolicySupervisor.start(domain(), :pending)
    {:ok, session} = SupervisionSession.start(policy, registry, [:fond])
    assert session.provider_id == :a

    {:ok, session} =
      SupervisionSession.observe_provider_health(
        session,
        session.provider_generation,
        :a,
        false
      )

    assert session.provider_id == :b

    assert {:ok, %{provider: %{id: :b}, policy: %{action: :attempt}}} =
             SupervisionSession.intent(session)
  end
end

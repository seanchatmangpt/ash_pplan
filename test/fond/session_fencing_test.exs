defmodule AshPPlan.FONDSessionFencingTest do
  @moduledoc """
  Generation fencing on the supervision session: an observation minted
  against a stale provider binding is refused typed before the registry is
  touched (plan P10 item 4).
  """

  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.FOND.{PolicySupervisor, ProviderRegistry, SupervisionSession}

  defp solvable_domain do
    {:ok, _} = FOND.new(%{pending: %{go: [:done]}, done: %{}}, [:done])
  end

  test "stale provider generation is refused typed before the registry moves" do
    {:ok, domain} = solvable_domain()
    {:ok, policy_sup} = PolicySupervisor.start(domain, :pending)
    registry = ProviderRegistry.new([%{id: :only, cost: 0}])
    {:ok, session} = SupervisionSession.start(policy_sup, registry, [])

    generation = session.provider_generation
    assert is_integer(generation)

    expected = generation + 100

    assert {:error, {:stale_generation, ^expected, actual}} =
             SupervisionSession.observe_provider_health(session, expected, :only, false)

    assert actual == generation

    # nothing moved: the registry generation and the bound provider survive
    assert session.provider_id == :only
    assert {:ok, rebound} =
             SupervisionSession.observe_provider_health(
               session,
               session.registry.generation,
               :only,
               true
             )

    assert rebound.provider_id == :only
  end

  test "a healthy observe at the current generation still rebinds on unhealth" do
    {:ok, domain} = solvable_domain()
    {:ok, policy_sup} = PolicySupervisor.start(domain, :pending)
    registry = ProviderRegistry.new([%{id: :only, cost: 0}])
    {:ok, session} = SupervisionSession.start(policy_sup, registry, [])

    # marking the bound provider unhealthy forces a rebind attempt; with no
    # healthy alternative the rebind refuses typed
    assert {:error, {:no_provider, []}} =
             SupervisionSession.observe_provider_health(
               session,
               session.registry.generation,
               :only,
               false
             )
  end
end

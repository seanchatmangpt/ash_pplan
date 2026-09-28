defmodule AshPPlan.ObanActorPersisterTest do
  # Mutates the global `:ash_oban` application environment, so it must not run
  # concurrently with any other test.
  use ExUnit.Case, async: false

  alias AshPPlan.Oban, as: ObanProjection

  @resource AshPPlan.ObanIntegrationResource

  setup do
    previous = Application.fetch_env(:ash_oban, :actor_persister)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ash_oban, :actor_persister, value)
        :error -> Application.delete_env(:ash_oban, :actor_persister)
      end
    end)
  end

  test "no trigger persister and no app-wide persister means no actor persistence" do
    Application.delete_env(:ash_oban, :actor_persister)

    assert {:ok, capabilities} = ObanProjection.capabilities(@resource)
    refute capabilities.actor_persistence?
  end

  test "an app-wide persister is resolved exactly as AshOban resolves it at runtime" do
    Application.put_env(:ash_oban, :actor_persister, AshPPlan.ObanActorPersisterTest.Persister)

    assert {:ok, capabilities} = ObanProjection.capabilities(@resource)
    assert capabilities.actor_persistence?

    assert {:ok, activation} = ObanProjection.fetch_activation(@resource, :process)
    assert activation.authority.actor_persister == nil

    assert activation.authority.resolved_actor_persister ==
             AshPPlan.ObanActorPersisterTest.Persister

    assert {:ok, control_plane} = AshPPlan.ControlPlane.describe(@resource)
    assert control_plane.closure.actor_propagation?
  end

  test "an app-wide :none disables actor persistence" do
    Application.put_env(:ash_oban, :actor_persister, :none)

    assert {:ok, capabilities} = ObanProjection.capabilities(@resource)
    refute capabilities.actor_persistence?
  end
end

defmodule AshPPlan.ControlPlaneTest do
  use ExUnit.Case, async: true

  alias AshPPlan.ControlPlane

  test "joins one action across lifecycle and background activation without actuation" do
    assert {:ok, control_plane} =
             ControlPlane.describe(AshPPlan.ControlPlaneIntegrationResource)

    assert control_plane.state_machine.available?
    assert control_plane.oban.available?
    assert control_plane.closure.persistent_resource_lifecycle?
    assert control_plane.closure.lifecycle_policy_preflight?
    assert control_plane.closure.lifecycle_atomic_transition?
    assert control_plane.closure.lifecycle_possible_next_states?
    assert control_plane.closure.background_activation?
    assert control_plane.closure.retry_delivery?
    assert control_plane.closure.stable_background_identity?

    refute control_plane.closure.temporal_activation?
    refute control_plane.closure.actor_propagation?
    refute control_plane.closure.tenant_propagation?
    refute control_plane.closure.shared_job_context?
    refute control_plane.closure.chunk_processing?

    process = Enum.find(control_plane.action_links, &(&1.name == :process))

    assert process.state_transition?
    assert process.background_activation?
    refute process.temporal_activation?
    assert process.activations == [%{kind: :trigger, name: :process}]

    assert control_plane.authority.domain_state == Ash
    assert control_plane.authority.lifecycle_legality == AshStateMachine
    assert control_plane.authority.background_and_temporal_delivery == AshOban
    assert control_plane.authority.queue_runtime == Oban
    assert control_plane.authority.saga_execution == Reactor
  end

  test "retains explicit authority gaps instead of manufacturing runtime ownership" do
    assert {:ok, control_plane} =
             ControlPlane.describe(AshPPlan.ControlPlaneIntegrationResource)

    refute control_plane.gaps.universal_continuation_store?
    refute control_plane.gaps.planner_actuation?
    refute control_plane.gaps.duplicated_queue_runtime?
    refute control_plane.gaps.duplicated_state_machine_runtime?
  end
end

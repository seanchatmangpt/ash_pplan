defmodule AshPPlan.ControlPlaneTest do
  use ExUnit.Case, async: true

  alias AshPPlan.ControlPlane

  test "joins one action across lifecycle and background activation without actuation" do
    assert {:ok, control_plane} =
             ControlPlane.describe(AshPPlan.ControlPlaneIntegrationResource)

    assert control_plane.state_machine.available?
    assert control_plane.oban.available?
    assert control_plane.closure.persistent_resource_lifecycle?
    refute control_plane.closure.lifecycle_policy_preflight?
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

  test "a plain Ash resource composes with every lifecycle and delivery claim false" do
    assert {:ok, control_plane} = ControlPlane.describe(AshPPlan.DescriptorFixtures.PlainResource)

    refute control_plane.state_machine.available?
    assert control_plane.state_machine.error.reason == :ash_state_machine_not_configured
    refute control_plane.oban.available?
    assert control_plane.oban.error.reason == :ash_oban_not_configured

    for {key, value} <- control_plane.closure,
        key not in [
          :hierarchical_process_semantics?,
          :nondeterministic_policy_validation?,
          :semantic_reactor_execution?,
          :durable_continuation_contract?
        ] do
      refute value, "#{key} claimed for a resource without either extension"
    end

    assert Enum.all?(control_plane.action_links, &(not &1.state_transition?))
    assert Enum.all?(control_plane.action_links, &(&1.activations == []))
  end

  test "refuses modules that are not Ash resources" do
    assert {:error, %{reason: :not_an_ash_resource, resource: URI}} = ControlPlane.describe(URI)

    assert {:error, %{reason: :not_an_ash_resource}} =
             ControlPlane.describe(NoSuch.ControlPlaneModule)
  end

  test "a lifecycle-only resource uses configured lifecycle facts, not upstream support" do
    assert {:ok, control_plane} =
             ControlPlane.describe(AshPPlan.DescriptorFixtures.MinimalLifecycle)

    assert control_plane.state_machine.available?
    refute control_plane.oban.available?
    assert control_plane.closure.persistent_resource_lifecycle?
    assert control_plane.closure.lifecycle_atomic_transition?
    refute control_plane.closure.lifecycle_policy_preflight?
    refute control_plane.closure.background_activation?

    publish = Enum.find(control_plane.action_links, &(&1.name == :publish))
    all = Enum.find(control_plane.action_links, &(&1.name == :all))
    assert publish.state_transition?
    refute all.state_transition?
  end

  test "action: :* links every update action; the upsert create links only explicitly" do
    assert {:ok, control_plane} =
             ControlPlane.describe(AshPPlan.DescriptorFixtures.ConfiguredLifecycle)

    linked =
      for link <- control_plane.action_links, link.state_transition?, do: link.name

    assert Enum.sort(linked) == [:advance, :archive, :restore, :upsert_pending]
    refute :read in linked
  end

  test "a delivery-only resource composes AshOban facts without lifecycle claims" do
    assert {:ok, control_plane} = ControlPlane.describe(AshPPlan.ObanIntegrationResource)

    refute control_plane.state_machine.available?
    assert control_plane.oban.available?
    refute control_plane.closure.persistent_resource_lifecycle?
    refute control_plane.closure.lifecycle_atomic_transition?
    assert control_plane.closure.background_activation?
    assert control_plane.closure.temporal_activation?
    assert control_plane.closure.shared_job_context?
    assert control_plane.authority.lifecycle_legality == AshStateMachine

    tick = Enum.find(control_plane.action_links, &(&1.name == :tick))
    assert tick.temporal_activation?
    refute tick.background_activation?
  end

  test "a deleted trigger is linked but claims no live background activation" do
    assert {:ok, control_plane} =
             ControlPlane.describe(AshPPlan.DescriptorFixtures.DeletedTriggerOban)

    refute control_plane.closure.background_activation?
    refute control_plane.closure.temporal_activation?
    refute control_plane.closure.retry_delivery?
    refute control_plane.closure.snooze_cancel_control?

    retire = Enum.find(control_plane.action_links, &(&1.name == :retire))
    assert retire.activations == [%{kind: :trigger, name: :retire}]
    refute retire.background_activation?
    refute retire.temporal_activation?
  end

  test "tenant propagation follows the resolved oban-section tenant list" do
    assert {:ok, control_plane} =
             ControlPlane.describe(AshPPlan.DescriptorFixtures.SectionTenantsOban)

    assert control_plane.closure.tenant_propagation?
    assert control_plane.closure.actor_propagation?
  end
end

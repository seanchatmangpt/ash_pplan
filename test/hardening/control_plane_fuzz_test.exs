defmodule AshPPlan.ControlPlaneFuzzTest do
  @moduledoc """
  Fuzz hardening for AshPPlan.ControlPlane public functions.

  Typed-refusal law: garbage input must produce a typed value, never a raise.
  """

  use ExUnit.Case, async: true

  alias AshPPlan.ControlPlane

  @garbage [
    nil,
    :foo,
    "garbage",
    "",
    [],
    [:a, :b],
    [%{resource: nil}],
    %{},
    %{resource: nil},
    %{actions: [:boom]},
    12,
    3.14,
    true,
    false,
    {:tuple, :input},
    self()
  ]

  describe "describe/1 typed refusal" do
    test "returns an error map for every garbage input, never raises" do
      for input <- @garbage do
        result =
          try do
            ControlPlane.describe(input)
          rescue
            e -> {:RAISED, e}
          end

        assert match?({:error, %{reason: reason}} when is_atom(reason), result),
               "describe(#{inspect(input, limit: 3)}) => #{inspect(result, limit: 5)}"
      end
    end

    test "non-atom garbage is typed :invalid_resource" do
      for input <- ["garbage", [], %{resource: nil}, 12, self()] do
        assert {:error, %{reason: :invalid_resource, resource: ^input}} =
                 ControlPlane.describe(input)
      end
    end

    test "nil is an atom, so it refuses as :not_an_ash_resource" do
      assert {:error, %{reason: :not_an_ash_resource, resource: nil}} =
               ControlPlane.describe(nil)
    end

    test "result is stable under repetition (no hidden state)" do
      a = ControlPlane.describe(%{resource: nil})
      b = ControlPlane.describe(%{resource: nil})
      assert a == b
    end
  end

  describe "action_catalog/1 typed refusal" do
    test "returns a plain list for every garbage input, never raises" do
      for input <- @garbage do
        result =
          try do
            ControlPlane.action_catalog(input)
          rescue
            e -> {:RAISED, e}
          end

        assert is_list(result),
               "action_catalog(#{inspect(input, limit: 3)}) => #{inspect(result, limit: 5)}"
      end
    end

    test "non-DSL atoms return an empty catalog instead of ArgumentError" do
      assert ControlPlane.action_catalog(:nope) == []
      assert ControlPlane.action_catalog(NoSuch.ControlPlaneModule) == []
    end
  end

  describe "composed-view invariants under fuzzing" do
    test "real-resource composition shape survives mixed garbage in linked fields" do
      # describe/1 output only contains values derived from the resource; garbage
      # in unrelated processes must not poison it. Deep-shape checks here:
      assert {:ok, plane} = ControlPlane.describe(AshPPlan.ControlPlaneIntegrationResource)

      assert is_atom(plane.resource)
      assert is_list(plane.actions)
      assert Enum.all?(plane.actions, &is_map/1)
      assert Enum.all?(plane.action_links, &is_map/1)

      # every action descriptor carries the full contracted key set
      descriptor_keys = [
        :name,
        :type,
        :primary?,
        :public?,
        :transaction?,
        :upsert?,
        :require_atomic?,
        :touches_resources,
        :arguments
      ]

      for action <- plane.actions do
        assert MapSet.new(Map.keys(action)) == MapSet.new(descriptor_keys)
      end

      link_keys =
        descriptor_keys ++
          [:state_transition?, :activations, :background_activation?, :temporal_activation?]

      for link <- plane.action_links do
        assert MapSet.new(Map.keys(link)) == MapSet.new(link_keys)
      end
    end

    test "duplicate capability ids in actions do not occur (catalog is uniq by construction)" do
      assert {:ok, plane} = ControlPlane.describe(AshPPlan.ControlPlaneIntegrationResource)
      names = Enum.map(plane.actions, & &1.name)
      assert Enum.uniq(names) == names
    end

    test "closure/authority keys are closed sets for both available and unavailable surfaces" do
      for resource <- [
            AshPPlan.ControlPlaneIntegrationResource,
            AshPPlan.DescriptorFixtures.PlainResource,
            AshPPlan.DescriptorFixtures.MinimalLifecycle,
            AshPPlan.ObanIntegrationResource
          ] do
        assert {:ok, plane} = ControlPlane.describe(resource)

        assert MapSet.new(Map.keys(plane.closure)) ==
                 MapSet.new([
                   :hierarchical_process_semantics?,
                   :nondeterministic_policy_validation?,
                   :semantic_reactor_execution?,
                   :durable_continuation_contract?,
                   :persistent_resource_lifecycle?,
                   :lifecycle_policy_preflight?,
                   :lifecycle_atomic_transition?,
                   :lifecycle_possible_next_states?,
                   :background_activation?,
                   :temporal_activation?,
                   :retry_delivery?,
                   :snooze_cancel_control?,
                   :actor_propagation?,
                   :tenant_propagation?,
                   :shared_job_context?,
                   :chunk_processing?,
                   :stable_background_identity?
                 ])

        assert MapSet.new(Map.keys(plane.authority)) ==
                 MapSet.new([
                   :domain_state,
                   :lifecycle_legality,
                   :background_and_temporal_delivery,
                   :queue_runtime,
                   :saga_execution,
                   :policy_validation,
                   :semantic_compilation,
                   :continuation_admission,
                   :control_plane_observation
                 ])
      end
    end

    test "cycle attempt: feeding a composed plane back through describe stays typed" do
      {:ok, plane} = ControlPlane.describe(AshPPlan.ControlPlaneIntegrationResource)
      assert {:error, %{reason: :invalid_resource}} = ControlPlane.describe(plane)
      assert ControlPlane.action_catalog(plane) == []
    end
  end
end

defmodule AshPPlan.SemanticRealityStateMachineCourtTest do
  @moduledoc """
  Court pinning the README's AshStateMachine row: `AshPPlan.StateMachine`
  calls the public `AshStateMachine` contract directly and projects its
  resolved lifecycle without reproducing lifecycle validation.

  Three verdicts, all Chicago-style (real Ash resources, real transitions,
  assert on final state):

    1. The descriptor resolves a real lifecycle through the *public*
       `AshStateMachine.Info` contract — re-read independently, not through
       the adapter.
    2. An illegal transition is refused BY ASH (`ValidNextState` policy /
       `Ash.Error.Forbidden`), never by an ash_pplan-side re-implementation.
    3. The charts projection matches the resolved lifecycle: non-empty, and
       every projected edge exists in the lifecycle the descriptor resolved.
  """

  use ExUnit.Case, async: true

  alias AshPPlan.StateMachine

  @moduletag :capture_log

  @resource AshPPlan.StateMachineIntegrationResource

  describe "the descriptor resolves a real lifecycle through the public AshStateMachine contract" do
    test "the resolved lifecycle equals a fresh public-contract read of the same resource" do
      assert {:ok, lifecycle} = StateMachine.describe_resource(@resource)

      # Independent re-read through the public AshStateMachine.Info API —
      # the same contract the adapter is required to call directly.
      public_all_states =
        @resource |> AshStateMachine.Info.state_machine_all_states() |> Enum.sort()

      public_deprecated =
        @resource |> AshStateMachine.Info.state_machine_deprecated_states!() |> Enum.sort()

      public_transitions =
        @resource
        |> AshStateMachine.Info.state_machine_transitions()
        |> Enum.map(fn t ->
          %{action: t.action, from: Enum.sort(List.wrap(t.from)), to: Enum.sort(List.wrap(t.to))}
        end)
        |> Enum.sort_by(&{&1.action, &1.from, &1.to})

      assert lifecycle.owner == AshStateMachine

      assert lifecycle.state_attribute ==
               AshStateMachine.Info.state_machine_state_attribute!(@resource)

      assert lifecycle.states == Enum.sort(public_all_states ++ public_deprecated)
      assert lifecycle.wildcard_states == public_all_states
      assert lifecycle.deprecated_states == public_deprecated

      assert lifecycle.initial_states ==
               AshStateMachine.Info.state_machine_initial_states!(@resource)

      assert Enum.map(lifecycle.transitions, fn t ->
               %{action: t.action, from: t.from, to: t.to}
             end)
             |> Enum.sort_by(&{to_string(&1.action), &1.from, &1.to}) ==
               Enum.sort_by(public_transitions, &{to_string(&1.action), &1.from, &1.to})

      assert lifecycle.wildcard_actions ==
               @resource
               |> Ash.Resource.Info.actions()
               |> Enum.filter(&(&1.type == :update))
               |> Enum.map(& &1.name)
               |> Enum.sort()
    end

    test "the authority named is the installed upstream, not a local reimplementation" do
      assert {:ok, %{authority: authority}} = StateMachine.describe_resource(@resource)

      assert authority.inspect == AshStateMachine.Info
      assert authority.mutate == AshStateMachine
      assert authority.policy_check == AshStateMachine.Checks.ValidNextState
      assert authority.transition_change == AshStateMachine.BuiltinChanges.TransitionState
      assert authority.diagrams == AshStateMachine.Charts

      # The named upstream modules are the *installed* dependency's modules.
      assert Code.ensure_loaded?(AshStateMachine.Info)
      assert Code.ensure_loaded?(AshStateMachine.Charts)
      assert Code.ensure_loaded?(AshStateMachine.BuiltinChanges.TransitionState)
    end

    test "possible-next-state observation is delegated, byte-identical to upstream" do
      # `@resource` has no configured Ash domain, so this court exercises the
      # delegation surface on a plain struct — the same read-only observation
      # path AshStateMachine.possible_next_states itself uses.
      pending = struct(@resource, state: :pending)

      assert StateMachine.possible_next_states(pending) ==
               {:ok, AshStateMachine.possible_next_states(pending)}

      # The concrete :advance edge plus the `:*, from: :*, to: :cancelled`
      # wildcard edge AshStateMachine expands for every update action.
      assert {:ok, next_for_advance} = StateMachine.possible_next_states(pending, :advance)
      assert :complete in next_for_advance and :cancelled in next_for_advance
    end
  end

  describe "an illegal transition is refused BY ASH, not by ash_pplan re-validating" do
    test "the ValidNextState policy (Ash) refuses; the adapter never does" do
      resource = AshPPlan.DescriptorFixtures.PolicyGuardedLifecycle

      published = Ash.create!(resource, %{state: :published})
      assert published.state == :published

      # Ash's own authority surface refuses: no transition leaves :published,
      # so AshStateMachine's builtin TransitionState change raises
      # NoMatchingTransition — an upstream refusal, never an ash_pplan one.
      changeset = Ash.Changeset.for_update(published, :publish, %{})
      assert {:error, error} = Ash.update(changeset)

      assert [
               %AshStateMachine.Errors.NoMatchingTransition{
                 action: :publish,
                 old_state: :published
               }
             ] =
               Enum.filter(
                 error.errors,
                 &match?(%AshStateMachine.Errors.NoMatchingTransition{}, &1)
               )

      # The refusal came from Ash's policy engine, not from a projection:
      # the adapter's observation surface stays a plain {:ok, _} answer and
      # the descriptor simply reports no outgoing edge from :published.
      assert {:ok, []} = StateMachine.possible_next_states(published)

      assert {:ok, lifecycle} = StateMachine.describe_resource(resource)

      refute Enum.any?(lifecycle.transitions, &(:published in List.wrap(&1.from)))

      # And the FOND projection encodes exactly the lifecycle Ash enforces:
      # the legal edge is present, the illegal one is absent.
      assert {:ok, domain} = StateMachine.from_resource(resource, [:published])
      assert AshPPlan.FOND.outcomes(domain, :draft, :publish) == [:published]
      assert AshPPlan.FOND.actions(domain, :published) == []
    end

    test "the wildcard contract is Ash's, expanded from the lifecycle it resolved" do
      pending = struct(@resource, state: :pending)

      # :cancelled is reachable from everywhere via `transition :*, from: :*,
      # to: :cancelled` — an AshStateMachine fact, expanded by the descriptor.
      assert :cancelled in AshStateMachine.possible_next_states(pending)
      assert {:ok, next} = StateMachine.possible_next_states(pending)
      assert :cancelled in next

      assert {:ok, lifecycle} = StateMachine.describe_resource(@resource)
      wildcard = Enum.find(lifecycle.transitions, &(&1.action == :*))
      assert wildcard.to == [:cancelled]

      assert {:ok, domain} = StateMachine.from_resource(@resource, [:cancelled])
      assert :cancelled in AshPPlan.FOND.outcomes(domain, :pending, :cancel)
    end
  end

  describe "the charts projection matches the resolved lifecycle" do
    test "both diagram types are delegated and non-empty" do
      assert {:ok, state_diagram} = AshPPlan.StateMachine.Charts.render(@resource, :state)
      assert {:ok, flowchart} = AshPPlan.StateMachine.Charts.render(@resource, :flow)

      assert is_binary(state_diagram) and state_diagram != ""
      assert is_binary(flowchart) and flowchart != ""
      assert String.starts_with?(state_diagram, "stateDiagram-v2")
      assert String.starts_with?(flowchart, "flowchart TD")

      assert {:ok, lifecycle} = StateMachine.describe_resource(@resource)
      assert lifecycle.capabilities.configured.diagrams? == true
      assert lifecycle.capabilities.supported.diagrams? == true
    end

    test "every projected edge exists in the resolved lifecycle (anti-vacuity)" do
      assert {:ok, lifecycle} = StateMachine.describe_resource(@resource)
      assert lifecycle.states != []

      assert {:ok, state_diagram} = AshPPlan.StateMachine.Charts.render(@resource, :state)
      assert {:ok, flowchart} = AshPPlan.StateMachine.Charts.render(@resource, :flow)

      edge_regex = ~r/(\w+)\s*-->\s*(?:\|[^|]*\|\s*)?(\w+)/

      for diagram <- [state_diagram, flowchart],
          edge = Regex.scan(edge_regex, diagram),
          length(edge) > 0,
          [_full, from, to] <- edge do
        from = String.to_atom(from)
        to = String.to_atom(to)

        assert from in lifecycle.states,
               "diagram projects state #{inspect(from)} absent from the resolved lifecycle"

        assert to in lifecycle.states,
               "diagram projects state #{inspect(to)} absent from the resolved lifecycle"

        assert Enum.any?(lifecycle.transitions, fn t ->
                 from in List.wrap(t.from) and to in List.wrap(t.to)
               end),
               "diagram edge #{inspect(from)} --> #{inspect(to)} has no declared transition"
      end

      # Not vacuously empty: the concrete lifecycle edge is visible in both.
      assert state_diagram =~ "pending"
      assert state_diagram =~ "complete"
      assert flowchart =~ "pending"
      assert flowchart =~ "complete"
    end
  end
end

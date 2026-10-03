defmodule AshPPlan.StateMachineHardeningTest do
  @moduledoc """
  HARDEN lane: adversarial inputs over the AshPPlan.StateMachine descriptor,
  its FOND transition projection, and the Charts delegation surface. Every
  malformed input must produce a typed refusal, never a crash, a
  silently-wrong projection, or a leaked wildcard.
  """

  use ExUnit.Case, async: true

  alias AshPPlan.StateMachine
  alias AshPPlan.StateMachine.Charts

  @lifecycle AshPPlan.DescriptorFixtures.MinimalLifecycle
  @plain AshPPlan.DescriptorFixtures.PlainResource

  describe "from_transitions malformed inputs" do
    test "empty state set is refused" do
      assert {:error, %{reason: :empty_state_machine}} =
               StateMachine.from_transitions([], [%{action: :x, from: :a, to: :b}])
    end

    test "non-list states transitions options are refused" do
      assert {:error, %{reason: :invalid_state_machine_projection}} =
               StateMachine.from_transitions(:states, [], [])

      assert {:error, %{reason: :invalid_state_machine_projection}} =
               StateMachine.from_transitions([:a], :transitions, [])

      assert {:error, %{reason: :invalid_state_machine_projection}} =
               StateMachine.from_transitions([:a], [], [:a], :not_opts)
    end

    test "non-map transition is refused" do
      assert {:error, %{reason: :invalid_state_machine_transition}} =
               StateMachine.from_transitions([:a], [:not_a_map], [])
    end

    test "transition missing keys is refused" do
      assert {:error, %{reason: :invalid_state_machine_transition}} =
               StateMachine.from_transitions([:a], [%{action: :x, from: :a}], [])
    end

    test "garbage state term in from-list is refused" do
      assert {:error, %{reason: :unknown_state_in_transition, states: [:%]}} =
               StateMachine.from_transitions([:a], [%{action: :x, from: [:%], to: :a}], [])
    end

    test "nil source state is refused as unknown" do
      assert {:error, %{reason: :unknown_state_in_transition}} =
               StateMachine.from_transitions([:a], [%{action: :x, from: nil, to: :a}], [])
    end

    test "empty source or target expansion is refused" do
      assert {:error, %{reason: :empty_transition_source}} =
               StateMachine.from_transitions([:a], [%{action: :x, from: [], to: :a}], [])

      assert {:error, %{reason: :empty_transition_target}} =
               StateMachine.from_transitions([:a], [%{action: :x, from: :a, to: []}], [])
    end

    test "unknown goal states are refused, not projected as unreachable" do
      assert {:error, %{reason: :unknown_goal_states, states: [:ghost]}} =
               StateMachine.from_transitions([:a, :b], [%{action: :x, from: :a, to: :b}], [:ghost])
    end

    test "non-enumerable goal term is refused" do
      assert {:error, %{reason: :invalid_goal_states, goals: :a}} =
               StateMachine.from_transitions([:a], [], :a)
    end

    test "tuple-shaped goals are refused as unknown, never accepted" do
      assert {:error, %{reason: :unknown_goal_states}} =
               StateMachine.from_transitions([:a], [], %{a: 1})

      assert {:error, %{reason: :unknown_goal_states, states: [state: :a]}} =
               StateMachine.from_transitions([:a], [], state: :a)
    end

    test "wildcard state outside the declared state set is refused" do
      assert {:error, %{reason: :unknown_wildcard_state, states: [:ghost]}} =
               StateMachine.from_transitions(
                 [:a, :b],
                 [%{action: :x, from: :a, to: :b}],
                 [],
                 wildcard_states: [:a, :b, :ghost]
               )
    end

    test "literal star in wildcard_actions option is refused" do
      assert {:error, %{reason: :wildcard_action_must_be_concrete}} =
               StateMachine.from_transitions(
                 [:a],
                 [%{action: :*, from: :a, to: :a}],
                 [],
                 wildcard_actions: [:*]
               )
    end

    test "action star with no wildcard actions is refused" do
      assert {:error, %{reason: :wildcard_action_requires_actions}} =
               StateMachine.from_transitions([:a], [%{action: :*, from: :a, to: :a}], [])
    end

    test "literal star hidden inside an action list is refused, never leaks" do
      assert {:error, %{reason: :wildcard_action_requires_actions}} =
               StateMachine.from_transitions(
                 [:a, :b],
                 [%{action: [:x, :*], from: :a, to: :b}],
                 []
               )

      assert {:error, %{reason: :wildcard_action_requires_actions}} =
               StateMachine.from_transitions([:a], [%{action: [:y, :*], from: :a, to: :a}], [])
    end
  end

  describe "from_transitions happy paths" do
    test "concrete transition projects into the FOND relation" do
      assert {:ok, %AshPPlan.FOND{} = fond} =
               StateMachine.from_transitions([:a, :b], [%{action: :x, from: :a, to: :b}], [:b])

      assert MapSet.equal?(fond.goals, MapSet.new([:b]))
      assert fond.transitions[:a][:x] == [:b]
      assert fond.transitions[:b] == %{}
    end

    test "duplicate states goals and transitions deduplicate" do
      assert {:ok, fond} =
               StateMachine.from_transitions(
                 [:a, :a, :b],
                 [
                   %{action: :x, from: :a, to: :b},
                   %{action: :x, from: :a, to: :b}
                 ],
                 [:b, :b]
               )

      assert MapSet.equal?(fond.goals, MapSet.new([:b]))
      assert fond.transitions[:a][:x] == [:b]
    end

    test "action list expands to every listed action" do
      assert {:ok, fond} =
               StateMachine.from_transitions(
                 [:a, :b],
                 [%{action: [:x, :y], from: :a, to: :b}],
                 []
               )

      assert fond.transitions[:a][:x] == [:b]
      assert fond.transitions[:a][:y] == [:b]
    end

    test "action star expands across the wildcard action universe" do
      assert {:ok, fond} =
               StateMachine.from_transitions(
                 [:a, :b],
                 [%{action: :*, from: :a, to: :b}],
                 [],
                 wildcard_actions: [:x, :y]
               )

      assert fond.transitions[:a][:x] == [:b]
      assert fond.transitions[:a][:y] == [:b]
    end

    test "states with no transitions map to an empty action map" do
      assert {:ok, %AshPPlan.FOND{} = fond} = StateMachine.from_transitions([:a], [], [])
      assert fond.transitions == %{a: %{}}
    end
  end

  describe "describe_resource and capabilities" do
    test "non-ash resources are refused" do
      assert {:error, %{reason: :not_an_ash_resource}} = StateMachine.describe_resource(URI)
      assert {:error, %{reason: :not_an_ash_resource}} = StateMachine.describe_resource("nope")
      assert {:error, %{reason: :not_an_ash_resource}} = StateMachine.describe_resource(nil)

      assert {:error, %{reason: :not_an_ash_resource}} =
               StateMachine.capabilities("nope")
    end

    test "ash resource without AshStateMachine is refused as unconfigured" do
      assert {:error, %{reason: :ash_state_machine_not_configured}} =
               StateMachine.describe_resource(@plain)

      assert {:error, %{reason: :ash_state_machine_not_configured}} =
               StateMachine.capabilities(@plain)
    end

    test "configured lifecycle exposes a full descriptor" do
      assert {:ok, lifecycle} = StateMachine.describe_resource(@lifecycle)

      assert lifecycle.states == [:draft, :published]
      assert lifecycle.initial_states == [:draft]
      assert [%{action: :publish, from: [:draft], to: [:published]}] = lifecycle.transitions
      assert lifecycle.wildcard_states == [:draft, :published]
      assert is_map(lifecycle.capabilities) and is_map(lifecycle.capabilities.configured)

      assert {:ok, capabilities} = StateMachine.capabilities(@lifecycle)
      assert capabilities.configured.possible_next_states? == true
      assert capabilities.configured.diagrams? == true
      assert capabilities.configured.wildcard_transitions? == false
      assert capabilities.configured.deprecated_states_configured? == false
    end

    test "from_resource projects the declared lifecycle" do
      assert {:ok, fond} = StateMachine.from_resource(@lifecycle, [:published])
      assert MapSet.equal?(fond.goals, MapSet.new([:published]))
      assert fond.transitions[:draft][:publish] == [:published]
    end
  end

  describe "possible_next_states" do
    test "malformed records are refused" do
      assert {:error, %{reason: :invalid_state_machine_record}} =
               StateMachine.possible_next_states(nil)

      assert {:error, %{record: nil}} = StateMachine.possible_next_states(nil)

      assert {:error, %{reason: :not_an_ash_resource, resource: URI}} =
               StateMachine.possible_next_states(%URI{})
    end

    test "malformed actions are refused" do
      rec = struct(@lifecycle)

      assert {:error, %{reason: :unknown_state_machine_action}} =
               StateMachine.possible_next_states(rec, nil)

      assert {:error, %{reason: :invalid_state_machine_action}} =
               StateMachine.possible_next_states(rec, "publish")

      assert {:error, %{reason: :unknown_state_machine_action}} =
               StateMachine.possible_next_states(rec, :no_such_action)
    end

    test "delegates to AshStateMachine for configured records" do
      rec = struct(@lifecycle, state: :draft)
      assert {:ok, [:published]} = StateMachine.possible_next_states(rec)
      assert {:ok, [:published]} = StateMachine.possible_next_states(rec, :publish)
    end
  end

  describe "Charts render" do
    test "renders state and flow diagrams for a configured resource" do
      assert {:ok, state} = Charts.render(@lifecycle, :state)
      assert state =~ "stateDiagram-v2"
      assert state =~ "draft"
      assert state =~ "published"

      assert {:ok, flow} = Charts.render(@lifecycle, :flow)
      assert flow =~ "flowchart TD"
      assert flow =~ "draft"
    end

    test "default type is state" do
      assert {:ok, state} = Charts.render(@lifecycle)
      assert state =~ "stateDiagram-v2"
    end

    test "unsupported types on an atom resource are refused" do
      assert {:error, %{reason: :unsupported_diagram_type, type: :gantt}} =
               Charts.render(@lifecycle, :gantt)

      assert {:error, %{reason: :unsupported_diagram_type, type: nil}} =
               Charts.render(@lifecycle, nil)
    end

    test "non-atom resources are refused regardless of type" do
      assert {:error, %{reason: :not_an_ash_resource}} = Charts.render("resource")
      assert {:error, %{reason: :not_an_ash_resource}} = Charts.render(42, :state)
    end

    test "unconfigured resources are refused" do
      assert {:error, %{reason: :ash_state_machine_not_configured}} =
               Charts.render(@plain, :state)
    end
  end
end

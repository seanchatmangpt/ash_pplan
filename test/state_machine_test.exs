defmodule AshPPlan.StateMachineTest do
  use ExUnit.Case, async: true

  alias AshPPlan.{FOND, StateMachine}

  @moduletag :capture_log

  test "projects concrete AshStateMachine-style transitions into FOND outcomes" do
    transitions = [
      %{action: :begin_renewal, from: [:active], to: [:renewal_pending]},
      %{
        action: :renew,
        from: [:renewal_pending],
        to: [:active, :payment_failed]
      },
      %{action: :retry_payment, from: [:payment_failed], to: [:renewal_pending]}
    ]

    assert {:ok, domain} =
             StateMachine.from_transitions(
               [:active, :renewal_pending, :payment_failed],
               transitions,
               [:active]
             )

    assert FOND.actions(domain, :renewal_pending) == [:renew]
    assert FOND.outcomes(domain, :renewal_pending, :renew) == [:active, :payment_failed]
  end

  test "expands from/to wildcards against the admitted state set" do
    transitions = [
      %{action: :cancel, from: :*, to: [:cancelled]},
      %{action: :reset, from: [:cancelled], to: :*}
    ]

    assert {:ok, domain} =
             StateMachine.from_transitions([:active, :cancelled], transitions, [:cancelled])

    assert FOND.outcomes(domain, :active, :cancel) == [:cancelled]
    assert FOND.outcomes(domain, :cancelled, :reset) == [:active, :cancelled]
  end

  test "expands action wildcard to concrete update actions" do
    assert {:ok, domain} =
             StateMachine.from_transitions(
               [:active, :cancelled],
               [%{action: :*, from: [:active], to: [:cancelled]}],
               [:cancelled],
               wildcard_actions: [:cancel, :expire]
             )

    assert FOND.actions(domain, :active) == [:cancel, :expire]
    assert FOND.outcomes(domain, :active, :cancel) == [:cancelled]
    assert FOND.outcomes(domain, :active, :expire) == [:cancelled]
  end

  test "refuses action wildcard when no concrete action universe was supplied" do
    assert {:error, %{reason: :wildcard_action_requires_actions}} =
             StateMachine.from_transitions(
               [:active, :cancelled],
               [%{action: :*, from: :*, to: [:cancelled]}],
               [:cancelled]
             )
  end

  test "keeps deprecated states valid while excluding them from wildcard expansion" do
    transitions = [
      %{action: :cancel, from: :*, to: [:cancelled]},
      %{action: :restore_legacy, from: [:retired], to: [:active]}
    ]

    assert {:ok, domain} =
             StateMachine.from_transitions(
               [:active, :cancelled, :retired],
               transitions,
               [:cancelled],
               wildcard_states: [:active, :cancelled]
             )

    assert FOND.actions(domain, :retired) == [:restore_legacy]
    assert FOND.outcomes(domain, :retired, :cancel) == []
    assert FOND.outcomes(domain, :active, :cancel) == [:cancelled]
  end

  test "reads the real AshStateMachine lifecycle without widening deprecated wildcards" do
    assert {:ok, lifecycle} =
             StateMachine.describe_resource(AshPPlan.StateMachineIntegrationResource)

    assert lifecycle.owner == AshStateMachine
    assert lifecycle.state_attribute == :state
    assert lifecycle.initial_states == [:pending]
    assert lifecycle.default_initial_state == :pending
    assert :legacy in lifecycle.states
    refute :legacy in lifecycle.wildcard_states
    assert lifecycle.deprecated_states == [:legacy]
    assert lifecycle.wildcard_actions == [:advance, :cancel]
    assert lifecycle.capabilities.atomic_transition?
    assert lifecycle.capabilities.wildcard_transitions?
    assert lifecycle.capabilities.deprecated_states_configured?
    assert lifecycle.capabilities.diagrams?
    # Installed upstream support is not resource configuration: no policy uses
    # AshStateMachine.Checks.ValidNextState on this resource.
    assert lifecycle.capabilities.supported.policy_preflight?
    refute lifecycle.capabilities.policy_preflight?
    refute lifecycle.capabilities.configured.policy_preflight?
    assert lifecycle.authority.inspect == AshStateMachine.Info
    assert lifecycle.authority.mutate == AshStateMachine
  end

  test "projects the real extension wildcard action into the FOND relation" do
    assert {:ok, domain} =
             StateMachine.from_resource(
               AshPPlan.StateMachineIntegrationResource,
               [:cancelled]
             )

    assert FOND.actions(domain, :pending) == [:advance, :cancel]
    assert FOND.outcomes(domain, :pending, :cancel) == [:cancelled]
    assert FOND.actions(domain, :legacy) == []
  end

  test "refuses wildcard state universes containing undeclared states" do
    assert {:error, %{reason: :unknown_wildcard_state, states: [:missing]}} =
             StateMachine.from_transitions(
               [:active],
               [%{action: :advance, from: [:active], to: [:active]}],
               [],
               wildcard_states: [:active, :missing]
             )
  end

  test "refuses transitions that reference undeclared states" do
    assert {:error, %{reason: :unknown_state_in_transition, states: [:missing]}} =
             StateMachine.from_transitions(
               [:active],
               [%{action: :advance, from: [:active], to: [:missing]}]
             )
  end

  describe "goal validation" do
    test "refuses goals outside the lifecycle state set" do
      assert {:error, %{reason: :unknown_goal_states, states: [:ghost, :missing]}} =
               StateMachine.from_transitions(
                 [:active, :cancelled],
                 [%{action: :cancel, from: [:active], to: [:cancelled]}],
                 [:missing, :cancelled, :ghost]
               )
    end

    test "refuses non-enumerable goals" do
      assert {:error, %{reason: :invalid_goal_states, goals: :cancelled}} =
               StateMachine.from_transitions(
                 [:active, :cancelled],
                 [%{action: :cancel, from: [:active], to: [:cancelled]}],
                 :cancelled
               )
    end

    test "admits deprecated states as explicit goals" do
      assert {:ok, domain} =
               StateMachine.from_transitions(
                 [:active, :retired],
                 [%{action: :retire, from: [:active], to: [:retired]}],
                 [:retired],
                 wildcard_states: [:active]
               )

      assert domain.goals == MapSet.new([:retired])
    end

    test "from_resource refuses goals the real resource does not declare" do
      assert {:error, %{reason: :unknown_goal_states, states: [:nonexistent]}} =
               StateMachine.from_resource(AshPPlan.StateMachineIntegrationResource, [
                 :cancelled,
                 :nonexistent
               ])

      assert {:ok, _domain} =
               StateMachine.from_resource(AshPPlan.StateMachineIntegrationResource, [:legacy])
    end
  end

  describe "capability descriptor" do
    test "claims no optional lifecycle surface a resource does not configure" do
      assert {:ok, capabilities} =
               StateMachine.capabilities(AshPPlan.DescriptorFixtures.MinimalLifecycle)

      assert capabilities.atomic_transition?
      assert capabilities.possible_next_states?
      assert capabilities.create_initial_state?
      assert capabilities.diagrams?

      refute capabilities.wildcard_transitions?
      refute capabilities.policy_preflight?
      refute capabilities.next_state_change?
      refute capabilities.upsert_transition?
      refute capabilities.deprecated_states_configured?

      assert Map.drop(capabilities, [:supported, :configured]) == capabilities.configured
      assert Enum.all?(Map.values(capabilities.supported))
    end

    test "derives configured surfaces from actual transitions and action changes" do
      assert {:ok, capabilities} =
               StateMachine.capabilities(AshPPlan.DescriptorFixtures.ConfiguredLifecycle)

      assert capabilities.wildcard_transitions?
      assert capabilities.next_state_change?
      assert capabilities.upsert_transition?
      assert capabilities.deprecated_states_configured?
      assert capabilities.atomic_transition?
      refute capabilities.policy_preflight?
    end

    test "keeps an explicitly referenced deprecated state in the upstream wildcard universe" do
      assert {:ok, lifecycle} =
               StateMachine.describe_resource(AshPPlan.DescriptorFixtures.ConfiguredLifecycle)

      assert lifecycle.deprecated_states == [:legacy]
      assert :legacy in lifecycle.wildcard_states

      assert lifecycle.wildcard_states ==
               Enum.sort(
                 AshStateMachine.Info.state_machine_all_states(
                   AshPPlan.DescriptorFixtures.ConfiguredLifecycle
                 )
               )

      assert lifecycle.wildcard_actions == [:advance, :archive, :restore]
    end

    test "expands action: :* only to update actions, never to the upsert create" do
      assert {:ok, domain} =
               StateMachine.from_resource(AshPPlan.DescriptorFixtures.ConfiguredLifecycle, [
                 :archived
               ])

      assert FOND.outcomes(domain, :complete, :archive) == [:archived]
      assert FOND.outcomes(domain, :complete, :restore) == [:archived]
      assert FOND.outcomes(domain, :complete, :upsert_pending) == [:pending]
      assert FOND.actions(domain, :complete) == [:advance, :archive, :restore, :upsert_pending]
      assert FOND.actions(domain, :pending) == [:advance, :upsert_pending]
    end
  end

  test "does not claim state_always_selected? when the upstream preparation cannot select it" do
    # ash_state_machine 0.2.13 registers `ensure_selected: [ok: :state]` (the
    # non-bang Info result), so a narrowed select does not load the state.
    resource = AshPPlan.DescriptorFixtures.MinimalLifecycle
    Ash.create!(resource, %{})

    assert [%Ash.NotLoaded{} | _] =
             resource |> Ash.Query.select([:id]) |> Ash.read!() |> Enum.map(& &1.state)

    assert {:ok, capabilities} = StateMachine.capabilities(resource)
    assert capabilities.supported.state_always_selected?
    refute capabilities.state_always_selected?
  end

  describe "possible_next_states" do
    alias AshPPlan.DescriptorFixtures.{ConfiguredLifecycle, MinimalLifecycle}

    test "observes a persisted record through AshStateMachine" do
      draft = Ash.create!(MinimalLifecycle, %{})
      assert draft.state == :draft

      assert {:ok, [:published]} = StateMachine.possible_next_states(draft)
      assert {:ok, [:published]} = StateMachine.possible_next_states(draft, :publish)

      published = draft |> Ash.Changeset.for_update(:publish, %{}) |> Ash.update!()
      assert published.state == :published
      assert {:ok, []} = StateMachine.possible_next_states(published)
    end

    test "the public facade's one-argument form is the every-action view" do
      draft = Ash.create!(MinimalLifecycle, %{})

      assert AshPPlan.state_machine_next_states(draft) == StateMachine.possible_next_states(draft)
      assert {:ok, [:published]} = AshPPlan.state_machine_next_states(draft)
      assert {:ok, [:published]} = AshPPlan.state_machine_next_states(draft, :publish)
    end

    test "treats an action literally named :all as that action" do
      draft = Ash.create!(MinimalLifecycle, %{})

      assert {:ok, []} = StateMachine.possible_next_states(draft, :all)
      assert AshStateMachine.possible_next_states(draft, :all) == []
      assert {:ok, [:published]} = StateMachine.possible_next_states(draft)
    end

    test "resolves action wildcard transitions for a concrete action" do
      record = struct(ConfiguredLifecycle, state: :complete)
      assert {:ok, [:archived]} = StateMachine.possible_next_states(record, :restore)
    end

    test "refuses unknown and non-atom actions instead of answering []" do
      draft = struct(MinimalLifecycle, state: :draft)

      assert {:error, %{reason: :unknown_state_machine_action, action: :missing}} =
               StateMachine.possible_next_states(draft, :missing)

      assert {:error, %{reason: :invalid_state_machine_action, action: "publish"}} =
               StateMachine.possible_next_states(draft, "publish")
    end

    test "refuses records that are not configured AshStateMachine resources" do
      assert {:error, %{reason: :not_an_ash_resource, resource: URI}} =
               StateMachine.possible_next_states(%URI{})

      assert {:error, %{reason: :ash_state_machine_not_configured}} =
               StateMachine.possible_next_states(%AshPPlan.DescriptorFixtures.PlainResource{})

      assert {:error, %{reason: :invalid_state_machine_record}} =
               StateMachine.possible_next_states(%{state: :draft})
    end
  end

  test "refuses modules that are not configured AshStateMachine resources" do
    assert {:error, %{reason: :not_an_ash_resource, resource: NoSuch.Module}} =
             StateMachine.describe_resource(NoSuch.Module)

    assert {:error, %{reason: :not_an_ash_resource, resource: URI}} =
             StateMachine.from_resource(URI)

    assert {:error, %{reason: :ash_state_machine_not_configured}} =
             StateMachine.capabilities(AshPPlan.DescriptorFixtures.PlainResource)
  end
end

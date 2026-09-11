defmodule AshPPlan.StateMachineTest do
  use ExUnit.Case, async: true

  alias AshPPlan.{FOND, StateMachine}

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

  test "refuses action wildcard because a planner must select a concrete Ash action" do
    assert {:error, %{reason: :wildcard_action_not_plannable}} =
             StateMachine.from_transitions(
               [:active, :cancelled],
               [%{action: :*, from: :*, to: [:cancelled]}],
               [:cancelled]
             )
  end

  test "refuses transitions that reference undeclared states" do
    assert {:error, %{reason: :unknown_state_in_transition, states: [:missing]}} =
             StateMachine.from_transitions(
               [:active],
               [%{action: :advance, from: [:active], to: [:missing]}]
             )
  end
end

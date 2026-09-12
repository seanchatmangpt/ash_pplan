defmodule AshPPlan.StateMachineIntegrationResource do
  @moduledoc """
  Shared `AshStateMachine` fixture resource used by
  `AshPPlan.StateMachineTest` and `AshPPlan.StateMachineChartsTest`.

  Lives under `test/support` (compiled via `mix compile` through
  `elixirc_paths(:test)`) rather than being inlined into either test file, so
  it is guaranteed to be defined before any test references it regardless of
  the order ExUnit requires individual `*_test.exs` files in.
  """

  use Ash.Resource,
    domain: nil,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshStateMachine]

  state_machine do
    initial_states [:pending]
    deprecated_states [:legacy]

    transitions do
      transition :advance, from: :pending, to: :complete
      transition :*, from: :*, to: :cancelled
    end
  end

  actions do
    default_accept :*
    defaults [:read, :create]

    update :advance do
      change transition_state(:complete)
    end

    update :cancel do
      change transition_state(:cancelled)
    end
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
  end
end

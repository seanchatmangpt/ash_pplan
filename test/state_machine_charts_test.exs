defmodule AshPPlan.StateMachineChartsIntegrationResource do
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

defmodule AshPPlan.StateMachineChartsTest do
  use ExUnit.Case, async: true

  alias AshPPlan.StateMachine.Charts

  test "delegates Mermaid state and flow diagrams to AshStateMachine" do
    resource = AshPPlan.StateMachineChartsIntegrationResource

    assert {:ok, state_diagram} = Charts.render(resource, :state)
    assert String.starts_with?(state_diagram, "stateDiagram-v2")
    assert state_diagram =~ "pending"
    assert state_diagram =~ "complete"

    assert {:ok, flowchart} = Charts.render(resource, :flow)
    assert String.starts_with?(flowchart, "flowchart TD")
    assert flowchart =~ "pending"
    assert flowchart =~ "complete"
  end
end

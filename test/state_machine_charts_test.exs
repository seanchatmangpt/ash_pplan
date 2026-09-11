defmodule AshPPlan.StateMachineChartsTest do
  use ExUnit.Case, async: true

  alias AshPPlan.StateMachine.Charts

  test "delegates Mermaid state and flow diagrams to AshStateMachine" do
    resource = AshPPlan.StateMachineIntegrationResource

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

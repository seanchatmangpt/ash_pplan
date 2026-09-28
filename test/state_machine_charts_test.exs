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

  test "refuses unsupported diagram types and unconfigured resources" do
    resource = AshPPlan.StateMachineIntegrationResource

    assert {:error, %{reason: :unsupported_diagram_type, type: :gantt}} =
             Charts.render(resource, :gantt)

    assert {:error, %{reason: :ash_state_machine_not_configured}} =
             Charts.render(AshPPlan.DescriptorFixtures.PlainResource)

    assert {:error, %{reason: :not_an_ash_resource}} = Charts.render(URI)
    assert {:error, %{reason: :not_an_ash_resource}} = Charts.render("resource")
  end
end

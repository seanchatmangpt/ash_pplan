defmodule AshPPlan.Courts.Dsl.PPlanCourtTest do
  @moduledoc """
  Court for the GENERATED project-local `pplan` Spark DSL section (lane
  SPARK-PATCHES): proves the DSL form expands to the same normalized
  `AshPPlan.Workflow.Model` as the verbose `Model.new` literal.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Workflow.Model

  defmodule DslForm do
    use AshPPlan.Dsl

    pplan do
      name("court_flow")
      goal("court_goal")
      task(:observe, capability: "Remote.Read", authority: :observe)

      task(:verify,
        capability: "Verification.Run",
        after: [:observe],
        outcomes: [:admitted, :failed]
      )
    end
  end

  defmodule WorkflowForm do
    use AshPPlan.Workflow

    workflow do
      name("court_flow")
      goal("court_goal")

      task(:observe, capability: "Remote.Read", authority: :observe)

      task(:verify,
        capability: "Verification.Run",
        after: [:observe],
        outcomes: [:admitted, :failed]
      )
    end
  end

  test "pplan section expands to the verbose Model.new literal" do
    {:ok, model} = AshPPlan.Workflow.model(DslForm)

    {:ok, verbose} =
      Model.new(
        name: "court_flow",
        version: 1,
        goal: "court_goal",
        tasks: [
          %{
            id: :observe,
            capability: "Remote.Read",
            depends_on: [],
            outcomes: [],
            properties: [],
            evidence: [],
            authority: :observe
          },
          %{
            id: :verify,
            capability: "Verification.Run",
            depends_on: [:observe],
            outcomes: [:admitted, :failed],
            properties: [],
            evidence: [],
            authority: :construct
          }
        ],
        methods: []
      )

    assert model == verbose
  end

  test "pplan form equals the hand-written workflow section for identical declarations" do
    {:ok, via_pplan} = AshPPlan.Workflow.model(DslForm)
    {:ok, via_workflow} = AshPPlan.Workflow.model(WorkflowForm)
    assert via_pplan == via_workflow
  end
end

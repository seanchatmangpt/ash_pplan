defmodule AshPPlan.Workflow.PPlanProjectionTest do
  @moduledoc """
  P-PLAN projection court: the plan map keeps every task and its ordering,
  agrees with `Subject.verify_projection/3`, and compiles to a real Reactor.
  Anti-vacuity: a dropped step and a severed predecessor are both refused.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Workflow.{Model, Subject}
  alias AshPPlan.Workflow.Project.PPlan

  defmodule Step do
    use Reactor.Step
    @impl true
    def run(_args, _ctx, _opts), do: {:ok, :done}
  end

  defp model do
    {:ok, m} =
      Model.new(
        name: :pp_wf,
        tasks: [
          [id: :observe, capability: "Work.Select"],
          [id: :plan, capability: "Work.Select", depends_on: [:observe]],
          [id: :build, capability: "Work.Select", depends_on: [:plan, :observe]]
        ]
      )

    m
  end

  test "projects iri, label and ordered steps from the correspondence" do
    m = model()
    plan = PPlan.project(m)
    assert plan.iri == "urn:ash-pplan:workflow:pp_wf"
    assert plan.label == "pp_wf"

    assert Enum.map(plan.steps, & &1.iri) ==
             Enum.map([:observe, :plan, :build], &Subject.correspondence("pp_wf", &1).pplan)

    build = List.last(plan.steps)
    assert length(build.predecessors) == 2
  end

  test "verifies against the subject correspondence" do
    m = model()
    assert :ok = Subject.verify_projection(m, :pplan, PPlan.project(m))
  end

  test "compiles to a real Reactor" do
    m = model()
    plan = PPlan.project(m)
    handlers = Map.new(plan.steps, &{&1.iri, Step})
    assert {:ok, %Reactor{}} = AshPPlan.Compiler.compile_spec(plan, handlers)
  end

  test "mutation: dropping a step is refused" do
    m = model()
    plan = PPlan.project(m)
    mutated = %{plan | steps: tl(plan.steps)}

    assert {:error, %{reason: :projection_diverges}} =
             Subject.verify_projection(m, :pplan, mutated)
  end

  test "mutation: severing a predecessor edge is refused" do
    m = model()
    plan = PPlan.project(m)
    steps = Enum.map(plan.steps, &%{&1 | predecessors: []})

    assert {:error, %{reason: :projection_order_lost}} =
             Subject.verify_projection(m, :pplan, %{plan | steps: steps})
  end
end

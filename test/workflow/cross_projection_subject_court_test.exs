defmodule AshPPlan.Workflow.CrossProjectionSubjectCourtTest do
  @moduledoc """
  Same Subject Court across all four projections of every generated workflow: P-PLAN, HDDL,
  FOND and Reactor must each be a projection of the one `Workflow.Model` and carry the
  correspondence ids of its `Workflow.Subject`. Mutation: a projection missing a task, or
  a model with a different task set, fails the correspondence check.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Workflow.{Model, Subject}
  alias AshPPlan.Workflow.Project.{FOND, HDDL, PPlan}

  @workflows [AshPPlan.Generated.Workflows.Ultracode, AshPPlan.Generated.Workflows.FileRelease]

  for wf <- @workflows do
    test "#{inspect(wf)}: every projection corresponds to one subject" do
      model = unquote(wf).model()
      assert :ok = Model.validate(model)
      subject = Subject.bind(model)

      assert :ok = Subject.verify_projection(model, :pplan, PPlan.project(model))
      assert :ok = Subject.verify_projection(model, :hddl, HDDL.render(model))
      assert {:ok, fond} = FOND.project(model)
      assert :ok = Subject.verify_projection(model, :fond, fond)

      assert subject.id == unquote(wf).subject().id
      assert subject.id == Subject.bind(model).id
    end
  end

  test "mutation: dropping a task from a projection input breaks correspondence" do
    model = AshPPlan.Generated.Workflows.Ultracode.model()
    mutated = %{model | tasks: Enum.drop(model.tasks, -1)}
    refute Subject.bind(model).id == Subject.bind(mutated).id
    assert {:error, _} = Subject.verify_projection(model, :pplan, PPlan.project(mutated))
  end
end

defmodule AshPPlan.Workflow.DslTest do
  @moduledoc """
  Court for the `use AshPPlan.Workflow` Spark DSL.

  Falsifies: (1) the DSL silently dropping `after`/outcomes/capabilities when
  producing the Model; (2) verifiers admitting duplicate ids, unknown or cyclic
  dependencies, unparseable capabilities, authority above :construct, duplicate
  outcomes or method references to undeclared tasks.

  Anti-vacuity: every verifier has a mutation case where the property is broken
  and compilation must fail with the matching message; the valid control compiles.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Workflow
  alias AshPPlan.Workflow.{Model, Subject}

  defp compile!(body, name \\ "T#{System.unique_integer([:positive])}") do
    mod = Module.concat(__MODULE__, name)

    Code.compile_string("""
    defmodule #{inspect(mod)} do
      use AshPPlan.Workflow
      #{body}
    end
    """)

    mod
  end

  defp refused(body) do
    {result, _} =
      ExUnit.CaptureIO.with_io(:stderr, fn ->
        try do
          compile!(body)
          :compiled
        rescue
          e -> {:raised, Exception.message(e)}
        end
      end)

    result
  end

  @valid """
  workflow do
    goal "verified"
    task :observe, capability: "Repository.Observe", outcomes: [:ok]
    task :select, capability: "Work.Select", after: [:observe]
    task :verify, capability: "Verification.Run", after: [:select], outcomes: [:admitted, :failed], evidence: [:log]
    method :m1, task: :ship, subtasks: [:observe, :select, :verify]
  end
  """

  test "valid DSL yields the normalized model with after mapped to depends_on" do
    mod = compile!(@valid)
    assert {:ok, %Model{} = model} = Workflow.model(mod)
    assert model.goal == "verified"
    assert model.name =~ "t"
    assert Enum.map(model.tasks, & &1.id) == [:observe, :select, :verify]
    verify = Enum.find(model.tasks, &(&1.id == :verify))
    assert verify.depends_on == [:select]
    assert verify.outcomes == [:admitted, :failed]
    assert verify.authority == :construct
    assert [%{id: :m1, subtasks: [:observe, :select, :verify]}] = model.methods
    assert model.outcome_topology.verify == [:admitted, :failed]
    assert model == mod.__ash_pplan_workflow__()
  end

  test "model identity is deterministic regardless of declaration order" do
    a =
      compile!(
        "workflow do\n name :same\n task :a, capability: \"Work.Select\"\n task :b, capability: \"Work.Select\", after: [:a]\n end"
      )

    b =
      compile!(
        "workflow do\n name :same\n task :b, capability: \"Work.Select\", after: [:a]\n task :a, capability: \"Work.Select\"\n end"
      )

    assert Subject.bind(a.__ash_pplan_workflow__()).id ==
             Subject.bind(b.__ash_pplan_workflow__()).id
  end

  test "model/1 accepts a Model and refuses non-workflows" do
    {:ok, model} = Workflow.model(compile!(@valid))
    assert {:ok, ^model} = Workflow.model(model)
    assert {:error, %{reason: :not_a_workflow}} = Workflow.model(String)
    bad = %{model | tasks: model.tasks ++ model.tasks}
    assert {:error, %{reason: :duplicate_tasks}} = Workflow.model(bad)
  end

  test "mutation: duplicate task ids are refused" do
    assert {:raised, msg} =
             refused(
               "workflow do\n task :a, capability: \"Work.Select\"\n task :a, capability: \"Work.Select\"\n end"
             )

    assert msg =~ "duplicate"
  end

  test "mutation: unknown dependency is refused" do
    assert {:raised, msg} =
             refused("workflow do\n task :a, capability: \"Work.Select\", after: [:ghost]\n end")

    assert msg =~ "unknown dependencies"
  end

  test "mutation: dependency cycle is refused" do
    body = """
    workflow do
      task :a, capability: "Work.Select", after: [:b]
      task :b, capability: "Work.Select", after: [:a]
    end
    """

    assert {:raised, msg} = refused(body)
    assert msg =~ "cycle"
  end

  test "mutation: unparseable capability is refused" do
    assert {:raised, msg} = refused("workflow do\n task :a, capability: \"nonsense\"\n end")
    assert msg =~ "capability"
    assert {:raised, _} = refused("workflow do\n task :a, capability: \"Bogus.Name\"\n end")
  end

  test "mutation: authority above :construct (:do) is refused" do
    assert {:raised, msg} =
             refused("workflow do\n task :a, capability: \"Work.Select\", authority: :do\n end")

    assert msg =~ "authority"
  end

  test "mutation: duplicate outcomes are refused" do
    assert {:raised, msg} =
             refused(
               "workflow do\n task :a, capability: \"Work.Select\", outcomes: [:x, :x]\n end"
             )

    assert msg =~ "outcomes"
  end

  test "mutation: method referencing undeclared task is refused" do
    body =
      "workflow do\n task :a, capability: \"Work.Select\"\n method :m, task: :c, subtasks: [:zzz]\n end"

    assert {:raised, msg} = refused(body)
    assert msg =~ "undeclared"
  end

  test "control: the same shapes without the mutation compile" do
    assert :compiled ==
             refused(
               "workflow do\n task :a, capability: \"Work.Select\", outcomes: [:x, :y]\n task :b, capability: \"File.Write\", after: [:a]\n end"
             )
  end
end

defmodule AshPPlan.POWL.ProjectTest do
  use ExUnit.Case, async: true

  alias AshPPlan.POWL
  alias AshPPlan.POWL.Project
  alias AshPPlan.Workflow.Model

  @capability "workflow.execute"

  defp round_trip(model, name \\ "powl-projection") do
    assert {:ok, %{steps: steps} = result} = Project.to_reactor_steps(model)

    assert {:ok, compiled} = Model.new(name: name, tasks: steps)
    assert :ok = Model.validate(compiled)

    result
  end

  describe "sound models project and round-trip through Model.new" do
    test "leaf-only model" do
      model = POWL.partial_order("po", [POWL.activity("a"), POWL.activity("b")], [])

      result = round_trip(model)

      assert length(result.steps) == 2
      ids = Enum.map(result.steps, & &1[:id])
      assert MapSet.new(ids) |> MapSet.size() == 2
      assert Enum.all?(result.steps, &(&1[:capability] == @capability))
      # no structure → only uncompensable-leaf warnings
      assert Enum.all?(result.warnings, &(&1.warning == :uncompensable_activity))
    end

    test "sequence of choices" do
      model =
        POWL.sequence("s1", [
          POWL.choice("c1", [POWL.activity("a"), POWL.activity("b")]),
          POWL.choice("c2", [POWL.activity("c"), POWL.activity("d")])
        ])

      result = round_trip(model)

      # 2 discriminators + 4 branch leaves
      assert length(result.steps) == 6

      disc_ids = Enum.map(result.warnings, & &1[:discriminator]) |> Enum.reject(&is_nil/1)
      assert length(disc_ids) == 2

      ids = Enum.map(result.steps, & &1[:id])
      assert "c1__discriminator" in ids
      assert "c2__discriminator" in ids

      # branch leaves depend on their discriminator
      a = Enum.find(result.steps, &(&1[:id] == "a"))
      assert a[:depends_on] == ["c1__discriminator"]

      c = Enum.find(result.steps, &(&1[:id] == "c"))
      assert c[:depends_on] == ["c2__discriminator"]

      # sequence chaining: c2's discriminator depends on a c1 branch exit
      c2d = Enum.find(result.steps, &(&1[:id] == "c2__discriminator"))
      assert "a" in c2d[:depends_on] or "b" in c2d[:depends_on]
    end

    test "choice of sequences" do
      model =
        POWL.choice("c1", [
          POWL.sequence("s1", [POWL.activity("a"), POWL.activity("b")]),
          POWL.sequence("s2", [POWL.activity("c"), POWL.activity("d")])
        ])

      result = round_trip(model)

      # 1 discriminator + 4 leaves
      assert length(result.steps) == 5

      # within-branch sequencing: b depends on a; d depends on c
      b = Enum.find(result.steps, &(&1[:id] == "b"))
      assert b[:depends_on] == ["a"]

      d = Enum.find(result.steps, &(&1[:id] == "d"))
      assert d[:depends_on] == ["c"]

      # both branches hang off the one discriminator
      assert Enum.find(result.steps, &(&1[:id] == "a"))[:depends_on] == ["c1__discriminator"]
      assert Enum.find(result.steps, &(&1[:id] == "c"))[:depends_on] == ["c1__discriminator"]
    end

    test "loop composition projects a bounded retry with default max_iterations" do
      model = POWL.loop("l1", POWL.activity("body"), POWL.activity("redo"))

      result = round_trip(model)

      assert [retry] = result.steps
      assert retry[:id] == "l1__retry"

      prop = Enum.find(retry[:properties], &String.starts_with?(&1, "powl:max_iterations="))
      assert prop == "powl:max_iterations=3"

      assert %{warning: :loop_projected_as_bounded_retry, max_iterations: 3, block: "l1"} =
               Enum.find(result.warnings, &(&1.warning == :loop_projected_as_bounded_retry))
    end

    test "loop honors metadata max_iterations" do
      model = %POWL.Node{
        POWL.loop("l1", POWL.activity("body"), POWL.activity("redo"))
        | metadata: %{max_iterations: 7}
      }

      result = round_trip(model)

      retry = hd(result.steps)
      assert "powl:max_iterations=7" in retry[:properties]

      assert %{max_iterations: 7} =
               Enum.find(result.warnings, &(&1.warning == :loop_projected_as_bounded_retry))
    end

    test "partial order edges become depends_on DAG edges" do
      a = POWL.activity("a")
      inner = POWL.choice("inner", [POWL.activity("b1"), POWL.activity("b2")])
      d = POWL.activity("d")

      model = POWL.partial_order("po", [a, inner, d], [{"a", "inner"}, {"inner", "d"}])

      result = round_trip(model)

      assert length(result.steps) == 5

      assert Enum.find(result.steps, &(&1[:id] == "a"))[:depends_on] == []

      # the incoming edge from a lands on the choice block's discriminator;
      # the branches hang off the discriminator
      disc = Enum.find(result.steps, &(&1[:id] == "inner__discriminator"))
      assert disc[:depends_on] == ["a"]

      b1 = Enum.find(result.steps, &(&1[:id] == "b1"))
      assert b1[:depends_on] == ["inner__discriminator"]

      # d depends on the choice block's exits (both branch leaves)
      d = Enum.find(result.steps, &(&1[:id] == "d"))
      assert "b1" in d[:depends_on]
      assert "b2" in d[:depends_on]
    end

    test "leaf activity with metadata compensation projects the link in its step without a warning" do
      leaf = %POWL.Node{POWL.activity("a") | metadata: %{compensation: {Undo, :undo, []}}}
      model = POWL.partial_order("po", [leaf, POWL.activity("b")], [])

      result = round_trip(model)

      refute Map.has_key?(result, :compensations),
             "compensations side list must be retired: links ride in steps"

      a = Enum.find(result.steps, &(&1[:id] == "a"))
      assert a[:compensation] == {Undo, :undo, []}

      b = Enum.find(result.steps, &(&1[:id] == "b"))
      assert b[:compensation] == nil

      # round-trip court: the projected model carries the compensation value
      # in the Task struct and still validates.
      assert {:ok, compiled} = Model.new(name: "comp-round-trip", tasks: result.steps)
      assert :ok = Model.validate(compiled)

      task_a = Enum.find(compiled.tasks, &(&1.id == "a"))
      assert %AshPPlan.Workflow.Task{compensation: {Undo, :undo, []}} = task_a

      assert %AshPPlan.Workflow.Task{compensation: nil} =
               Enum.find(compiled.tasks, &(&1.id == "b"))

      warned_steps = Enum.map(result.warnings, & &1[:step])
      assert "a" not in warned_steps
      assert "b" in warned_steps
    end

    test "loop retry step carries its metadata compensation" do
      model = %POWL.Node{
        POWL.loop("l1", POWL.activity("body"), POWL.activity("redo"))
        | metadata: %{compensation: {Rollback, :run, []}}
      }

      result = round_trip(model)

      assert hd(result.steps)[:compensation] == {Rollback, :run, []}
    end
  end

  describe "refusals pass through with nothing projected" do
    test "PT-handle choice interior is refused" do
      a = POWL.activity("a")
      b = POWL.activity("b")
      c = POWL.choice("c", [POWL.activity("c1"), POWL.activity("c2")])

      model = POWL.partial_order("po", [a, b, c], [{"a", "c"}, {"b", "c"}])

      assert {:error,
              %{reason: :non_separable_block, block: %{cause: :pt_handle_choice_interior}}} =
               Project.to_reactor_steps(model)
    end

    test "order cycle is refused" do
      model =
        POWL.partial_order("po", [POWL.activity("a"), POWL.activity("b")], [
          {"a", "b"},
          {"b", "a"}
        ])

      assert {:error, %{reason: :non_separable_block, block: %{cause: :order_cycle}}} =
               Project.to_reactor_steps(model)
    end

    test "unsupported shape is refused" do
      assert {:error, %{reason: :unsupported_powl_shape}} = Project.to_reactor_steps("nope")
    end
  end

  describe "property: every catalog plan projects and compiles" do
    test "all catalog plans round-trip" do
      for plan <- AshPPlan.plans() do
        assert {:ok, %{steps: steps}} = Project.to_reactor_steps(plan)

        assert {:ok, compiled} = Model.new(name: plan.iri, tasks: steps)

        assert :ok = Model.validate(compiled),
               "catalog plan #{plan.iri} projection failed Model validation"
      end
    end
  end
end

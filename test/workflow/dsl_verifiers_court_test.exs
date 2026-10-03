defmodule AshPPlan.Workflow.DslVerifiersCourtTest do
  @moduledoc """
  P6 targeted courts for the four DSL verifiers and the GenerateModel
  transformer, driven through the real Spark DSL compile path
  (`Code.compile_string` of `use AshPPlan.Workflow` modules).

  Because `AshPPlan.Workflow.Dsl.Transformers.GenerateModel.transform/1` re-runs
  every verifier inside the transformer phase, a violated property fails
  compilation (raised, not merely warned). Each verifier gets:

    1. a mutation case where the property is broken — compilation must raise
       with the verifier's own message (not Spark's generic schema error), and
    2. a control case with the same shape minus the violation, which must
       compile and yield the expected model invariants.

  Anti-vacuity: message assertions are anchored on the verifier's distinctive
  wording so a regression where Spark's parse layer fires first (making the
  verifier dead code) fails the court.
  """

  use ExUnit.Case, async: true

  alias AshPPlan.Workflow
  alias AshPPlan.Workflow.Model

  defp compile_module(body, name \\ "C#{System.unique_integer([:positive])}") do
    mod = Module.concat(__MODULE__, name)

    Code.compile_string("""
    defmodule #{inspect(mod)} do
      use AshPPlan.Workflow
      #{body}
    end
    """)

    mod
  end

  # Compiles `body` capturing stderr; returns {:raised, msg} | {:ok, mod, io}.
  defp attempt(body) do
    {result, io} =
      ExUnit.CaptureIO.with_io(:stderr, fn ->
        try do
          {:ok, compile_module(body)}
        rescue
          e -> {:raised, Exception.message(e)}
        end
      end)

    {result, io}
  end

  defp compile_ok!(body) do
    {result, io} = attempt(body)

    assert {:ok, mod} = result,
           "expected clean compile, got: #{inspect(result)} io=#{inspect(io)}"

    # One-sided anti-noise check, not `io == ""`: the suite is async, so
    # compiler warnings from other tests' runtime defmodules can leak into this
    # capture. The load-bearing anti-vacuity property (verifier refusals are
    # hard compile errors, never silent stderr warnings) is asserted in
    # `refused/2` below and by the dedicated hard-error test.
    refute io =~ "cannot compile module", "unexpected stderr: #{inspect(io)}"

    mod
  end

  defp refused(body, expected_message) do
    {result, io} = attempt(body)

    assert {:raised, msg} = result, "expected compile to fail for: #{body}"
    assert msg =~ expected_message, "message #{inspect(msg)} lacks #{inspect(expected_message)}"
    # Anti-vacuity: the verifier's refusal must surface as a raised compile
    # error, never merely as a stderr warning (one-sided, noise-tolerant).
    refute io =~ expected_message
    msg
  end

  # ---------------------------------------------------------------------------
  # OutcomeClosure
  # ---------------------------------------------------------------------------

  describe "OutcomeClosure" do
    test "duplicate outcomes within one task are refused with the verifier's message" do
      refused(
        ~s(workflow do\n task :a, capability: "Work.Select", outcomes: [:ok, :ok]\n end),
        "declares duplicate outcomes"
      )
    end

    test "control: distinct outcomes compile and land in the model verbatim" do
      mod =
        compile_ok!(
          ~s(workflow do\n task :a, capability: "Work.Select", outcomes: [:admitted, :failed]\n end)
        )

      assert {:ok, %Model{} = model} = Workflow.model(mod)
      assert [%{id: :a, outcomes: [:admitted, :failed]}] = model.tasks
      assert model.outcome_topology.a == [:admitted, :failed]
    end

    # Rationale for the deleted skip-marked falsifier: the moduledoc's claimed
    # "closure under the dependency relation" had no DSL referent — no task field
    # references another task's outcomes (`precondition` is free-form :any), and
    # `terminal_outcomes` is a runtime-struct field not exposed in the DSL. The
    # only real closure property (terminal_outcomes ⊆ outcomes) is enforced by
    # Model.validate/1, so the moduledoc was corrected to describe the actual
    # per-task checks (unique atoms) rather than implement vacuous DSL semantics.
  end

  # ---------------------------------------------------------------------------
  # AcyclicDependencies
  # ---------------------------------------------------------------------------

  describe "AcyclicDependencies" do
    test "unresolvable `after` reference is refused" do
      refused(
        ~s(workflow do\n task :a, capability: "Work.Select", after: [:ghost]\n end),
        "unknown dependencies"
      )
    end

    test "two-node cycle is refused and names the cyclic tasks" do
      msg =
        refused(
          """
          workflow do
            task :a, capability: "Work.Select", after: [:b]
            task :b, capability: "Work.Select", after: [:a]
          end
          """,
          "dependency cycle among tasks"
        )

      assert msg =~ "a" and msg =~ "b"
    end

    test "self-loop is refused" do
      refused(
        ~s(workflow do\n task :a, capability: "Work.Select", after: [:a]\n end),
        "dependency cycle among tasks"
      )
    end

    test "three-node cycle is refused regardless of declaration order" do
      refused(
        """
        workflow do
          task :c, capability: "Work.Select", after: [:a]
          task :b, capability: "Work.Select", after: [:c]
          task :a, capability: "Work.Select", after: [:b]
        end
        """,
        "dependency cycle among tasks"
      )
    end

    test "tasks merely downstream of a cycle are also flagged (Kahn residual)" do
      msg =
        refused(
          """
          workflow do
            task :a, capability: "Work.Select", after: [:b]
            task :b, capability: "Work.Select", after: [:a]
            task :c, capability: "Work.Select", after: [:b]
          end
          """,
          "dependency cycle among tasks"
        )

      assert msg =~ "c"
    end

    test "control: diamond DAG compiles" do
      mod =
        compile_ok!("""
        workflow do
          task :root, capability: "Work.Select"
          task :left, capability: "Work.Select", after: [:root]
          task :right, capability: "Work.Select", after: [:root]
          task :sink, capability: "Work.Select", after: [:left, :right]
        end
        """)

      assert {:ok, %Model{}} = Workflow.model(mod)
    end
  end

  # ---------------------------------------------------------------------------
  # CapabilitiesParse
  # ---------------------------------------------------------------------------

  describe "CapabilitiesParse" do
    test "capability outside Family.Name pattern is refused" do
      refused(
        ~s(workflow do\n task :a, capability: "nonsense"\n end),
        "unparseable capability"
      )
    end

    test "well-formed capability with unknown family is refused" do
      refused(
        ~s(workflow do\n task :a, capability: "Bogus.Name"\n end),
        "unparseable capability"
      )
    end

    test "authority above :construct is refused with the ceiling message" do
      refused(
        ~s(workflow do\n task :a, capability: "Work.Select", authority: :do\n end),
        "exceeds ceiling :construct"
      )
    end

    test "error names the offending task" do
      msg =
        refused(
          ~s(workflow do\n task :culprit, capability: "nonsense"\n end),
          "task :culprit has unparseable capability"
        )

      assert msg =~ ":culprit"
    end

    test "control: :observe authority within ceiling compiles and is preserved" do
      mod =
        compile_ok!(
          ~s(workflow do\n task :a, capability: "Repository.Observe", authority: :observe\n end)
        )

      assert {:ok, %Model{} = model} = Workflow.model(mod)
      assert [%{authority: :observe}] = model.tasks
    end
  end

  # ---------------------------------------------------------------------------
  # UniqueIds
  # ---------------------------------------------------------------------------

  describe "UniqueIds" do
    test "duplicate task ids are refused" do
      refused(
        ~s(workflow do\n task :a, capability: "Work.Select"\n task :a, capability: "Work.Select"\n end),
        "duplicate task ids"
      )
    end

    test "duplicate method ids are refused" do
      refused(
        """
        workflow do
          task :a, capability: "Work.Select"
          method :m, task: :compound, subtasks: [:a]
          method :m, task: :compound, subtasks: [:a]
        end
        """,
        "duplicate method ids"
      )
    end

    test "method subtasks referencing undeclared tasks are refused" do
      refused(
        """
        workflow do
          task :a, capability: "Work.Select"
          method :m, task: :compound, subtasks: [:a, :ghost]
        end
        """,
        "methods reference undeclared tasks"
      )
    end

    test "method `task:` may name a compound (undeclared) task — only subtasks must resolve" do
      mod =
        compile_ok!(
          ~s(workflow do\n task :a, capability: "Work.Select"\n method :m, task: :compound, subtasks: [:a]\n end)
        )

      assert {:ok, %Model{} = model} = Workflow.model(mod)
      assert [%{id: :m, task: :compound, subtasks: [:a]}] = model.methods
    end

    test "control: unique ids across tasks and methods compile" do
      mod =
        compile_ok!("""
        workflow do
          task :a, capability: "Work.Select"
          task :b, capability: "Work.Select", after: [:a]
          method :m1, task: :compound, subtasks: [:a, :b]
        end
        """)

      assert {:ok, %Model{}} = Workflow.model(mod)
    end
  end

  # ---------------------------------------------------------------------------
  # Transformers.GenerateModel
  # ---------------------------------------------------------------------------

  describe "Transformers.GenerateModel" do
    @valid """
    workflow do
      goal "invariants"
      task :z_task, capability: "Work.Select"
      task :a_task, capability: "Repository.Observe", after: [:z_task], outcomes: [:ok]
      method :m2, task: :compound, subtasks: [:a_task]
      method :m1, task: :compound, subtasks: [:z_task]
    end
    """

    test "generates __ash_pplan_workflow__/0 returning a validated model" do
      mod = compile_ok!(@valid)
      assert function_exported?(mod, :__ash_pplan_workflow__, 0)
      assert {:ok, %Model{} = model} = Workflow.model(mod)
      assert model.goal == "invariants"
    end

    test "invariant: tasks and methods are normalized sorted by id" do
      mod = compile_ok!(@valid)
      assert {:ok, model} = Workflow.model(mod)
      assert Enum.map(model.tasks, & &1.id) == [:a_task, :z_task]
      assert Enum.map(model.methods, & &1.id) == [:m1, :m2]
    end

    test "invariant: outcome_topology is complete over declared tasks" do
      mod = compile_ok!(@valid)
      assert {:ok, model} = Workflow.model(mod)
      assert MapSet.new(Map.keys(model.outcome_topology)) == MapSet.new([:a_task, :z_task])
      assert model.outcome_topology.a_task == [:ok]
      assert model.outcome_topology.z_task == []
    end

    test "invariant: `after` is mapped to depends_on" do
      mod = compile_ok!(@valid)
      assert {:ok, model} = Workflow.model(mod)
      assert [%{depends_on: [:z_task]}] = Enum.filter(model.tasks, &(&1.id == :a_task))
    end

    test "invariant: model identity is deterministic across independent compiles" do
      body = "workflow do\n name :same\n task :a, capability: \"Work.Select\"\n end"
      left = compile_ok!(body)
      right = compile_ok!(body)
      assert left.__ash_pplan_workflow__() == right.__ash_pplan_workflow__()
    end

    test "invariant: dotted atom capability is normalized to the Family.Name string" do
      mod =
        compile_ok!(~s(workflow do\n task :a, capability: :"Work.Select"\n end))

      assert {:ok, model} = Workflow.model(mod)
      assert [%{capability: "Work.Select"}] = model.tasks
    end

    test "verifier failure inside the transformer is a hard compile error, not a warning" do
      {result, io} =
        attempt(~s(workflow do\n task :a, capability: "Work.Select", after: [:ghost]\n end))

      assert {:raised, msg} = result
      assert msg =~ "unknown dependencies"
      refute io =~ "unknown dependencies"
    end
  end
end

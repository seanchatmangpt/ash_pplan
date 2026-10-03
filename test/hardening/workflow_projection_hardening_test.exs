defmodule AshPPlan.Workflow.Hardening.ProjectionTest do
  @moduledoc """
  Typed-refusal hardening for `AshPPlan.Workflow` task/keyword models and the
  fond/hddl/p_plan/reactor projections: every malformed input is a typed
  error, never a raise.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Workflow.Model
  alias AshPPlan.Workflow.Project.{FOND, HDDL, PPlan, Reactor}

  defp assert_typed({:error, %{reason: _} = err}, reason) when is_atom(reason) do
    assert %{reason: ^reason} = err
  end

  defp assert_typed({:error, reason}, expected) when is_map(reason) do
    flunk("expected reason #{inspect(expected)}, got map: #{inspect(reason)}")
  end

  defp assert_typed(other, expected) do
    flunk("expected {:error, %{reason: #{inspect(expected)}}}, got: #{inspect(other)}")
  end

  describe "Model.new/1 garbage attrs" do
    test "non-keyword non-map attrs" do
      assert_typed(Model.new(:garbage), :invalid_workflow_attrs)
      assert_typed(Model.new("nope"), :invalid_workflow_attrs)
    end

    test "missing workflow name" do
      assert_typed(Model.new(tasks: []), :missing_workflow_name)
      assert_typed(Model.new(name: 42, tasks: []), :missing_workflow_name)
    end

    test "tasks is not a list" do
      assert_typed(Model.new(name: "w", tasks: :garbage), :invalid_tasks)
      assert_typed(Model.new(name: "w", tasks: %{:a => %{}}), :invalid_tasks)
    end

    test "task entry is not a map/keyword/struct" do
      assert_typed(Model.new(name: "w", tasks: [:atom]), :invalid_task)
      assert_typed(Model.new(name: "w", tasks: [nil]), :invalid_task)
      assert_typed(Model.new(name: "w", tasks: [42]), :invalid_task)
    end

    test "task without id / nil id / non-atom id" do
      assert_typed(Model.new(name: "w", tasks: [%{capability: "File.Write"}]), :missing_task_id)

      assert_typed(
        Model.new(name: "w", tasks: [%{id: nil, capability: "File.Write"}]),
        :missing_task_id
      )

      assert_typed(
        Model.new(name: "w", tasks: [%{id: 42, capability: "File.Write"}]),
        :missing_task_id
      )
    end

    test "task with unknown fields" do
      assert_typed(
        Model.new(name: "w", tasks: [%{id: :a, capability: "File.Write", bogus: 1}]),
        :unknown_task_fields
      )
    end

    test "task with both after: and depends_on:" do
      assert_typed(
        Model.new(
          name: "w",
          tasks: [%{id: :a, capability: "File.Write", after: [], depends_on: []}]
        ),
        :ambiguous_dependency_key
      )
    end

    test "methods is not a list / method entries malformed" do
      task = %{id: :a, capability: "File.Write"}
      assert_typed(Model.new(name: "w", tasks: [task], methods: :x), :invalid_methods)
      assert_typed(Model.new(name: "w", tasks: [task], methods: [:x]), :invalid_method)
      assert_typed(Model.new(name: "w", tasks: [task], methods: [%{}]), :missing_method_id)

      assert_typed(
        Model.new(name: "w", tasks: [task], methods: [%{id: :m, bogus: 1}]),
        :unknown_method_fields
      )
    end

    test "non-atom capabilities survive construction but fail validate" do
      {:ok, m} = Model.new(name: "w", tasks: [%{id: :a, capability: "not a capability"}])
      assert {:error, %{reason: :invalid_capability, tasks: [:a]}} = Model.validate(m)
    end
  end

  describe "structural refusals (existing, regression-pinned)" do
    test "duplicate task ids" do
      t = %{id: :a, capability: "File.Write"}

      assert {:error, %{reason: :duplicate_tasks, tasks: [:a]}} =
               Model.new(name: "w", tasks: [t, t])
    end

    test "unknown dependency" do
      assert {:error, %{reason: :unknown_dependencies}} =
               Model.new(
                 name: "w",
                 tasks: [%{id: :a, capability: "File.Write", depends_on: [:ghost]}]
               )
    end

    test "cyclic after chain" do
      tasks = [
        %{id: :a, capability: "File.Write", depends_on: [:b]},
        %{id: :b, capability: "File.Write", depends_on: [:c]},
        %{id: :c, capability: "File.Write", depends_on: [:a]}
      ]

      assert {:error, %{reason: :cyclic_dependencies, tasks: [:a, :b, :c]}} =
               Model.new(name: "w", tasks: tasks)

      assert {:error, %{reason: :cyclic_dependencies}} =
               Model.topological_order([
                 %AshPPlan.Workflow.Task{id: :a, depends_on: [:b]},
                 %AshPPlan.Workflow.Task{id: :b, depends_on: [:a]}
               ])
    end

    test "authority above :construct ceiling" do
      {:ok, m} =
        Model.new(name: "w", tasks: [%{id: :a, capability: "File.Write", authority: :do}])

      assert {:error, %{reason: :authority_above_ceiling, ceiling: :construct}} =
               Model.validate(m)
    end

    test "empty task list builds a valid empty model" do
      assert {:ok, %Model{tasks: [], methods: []}} = Model.new(name: "empty", tasks: [])
    end
  end

  describe "FOND projection over malformed models" do
    test "non-model input is typed" do
      assert_typed(FOND.project(:garbage), :not_a_model)
      assert_typed(FOND.project(%{tasks: []}), :not_a_model)
    end

    test "empty task list still projects to a solvable trivial domain" do
      {:ok, m} = Model.new(name: "w", tasks: [])
      assert {:ok, %{policy: policy}} = FOND.project(m)
      assert policy == %{}
    end

    test "cyclic hand-built model refuses (no policy raised)" do
      bad =
        struct!(Model,
          name: "w",
          tasks: [
            %AshPPlan.Workflow.Task{id: :a, capability: "File.Write", depends_on: [:b]},
            %AshPPlan.Workflow.Task{id: :b, capability: "File.Write", depends_on: [:a]}
          ]
        )

      assert {:error, %{reason: :cyclic_dependencies}} = FOND.project(bad)
    end

    test "all-terminal task contributes no action; domain refuses empty outcome lists" do
      {:ok, m} =
        Model.new(
          name: "w",
          tasks: [
            %{
              id: :blocked,
              capability: "File.Write",
              outcomes: [:blocked],
              terminal_outcomes: [:blocked]
            }
          ]
        )

      assert {:ok, %{policy: nil, refusal: refusal}} = FOND.project(m)
      assert refusal != nil
    end
  end

  describe "HDDL projection parse hardening" do
    test "non-binary input is typed" do
      assert_typed(HDDL.parse(nil), :hddl_parse_error)
      assert_typed(HDDL.parse(42), :hddl_parse_error)
      assert_typed(HDDL.parse(:atom), :hddl_parse_error)
    end

    test "garbage binaries are typed parse errors, never raises" do
      for text <- [
            "",
            "(",
            ")",
            "(((",
            "not an sexp at all",
            "(define (domain) (:method m1 :parameters ())",
            "(define (domain d) (:method m1 :task)",
            "(define (domain d) (:method m1 :task (t_a) :ordered-subtasks)",
            "(define (domain d) (:method m1 :task :parameters ())",
            "(define (domain d) (:action a :parameters () :effect (and (d-a)) :precondition"
          ] do
        assert {:error, %{reason: :hddl_parse_error}} = HDDL.parse(text),
               "expected typed error for #{inspect(text)}"
      end
    end

    test "round trip of a real render still parses and courts :ok" do
      {:ok, model} =
        Model.new(
          name: "hardening",
          tasks: [
            %{id: :observe, capability: "File.Read"},
            %{id: :write, capability: "File.Write", depends_on: [:observe]}
          ]
        )

      text = HDDL.render(model)
      assert {:ok, parsed} = HDDL.parse(text)
      assert :ok = HDDL.court(model, text)
      assert parsed.domain == "wf-hardening"
      assert Map.has_key?(parsed.actions, "t_observe")
    end
  end

  describe "Reactor projection refusals" do
    test "non-model and non-map bindings are typed" do
      assert_typed(Reactor.project(:garbage, %{}), :not_a_model)

      {:ok, m} = Model.new(name: "w", tasks: [%{id: :a, capability: "File.Write"}])
      assert {:error, %{reason: :invalid_bindings}} = Reactor.project(m, :not_bindings)
    end

    test "unbound tasks are typed" do
      {:ok, m} = Model.new(name: "w", tasks: [%{id: :a, capability: "File.Write"}])
      assert {:error, %{reason: :unbound_tasks, tasks: [:a]}} = Reactor.project(m, %{})
    end
  end

  describe "P-PLAN projection" do
    test "respects dependency order on a valid model" do
      {:ok, m} =
        Model.new(
          name: "w",
          tasks: [
            %{id: :b, capability: "File.Write", depends_on: [:a]},
            %{id: :a, capability: "File.Read"}
          ]
        )

      plan = PPlan.project(m)
      assert Enum.any?(plan.steps, &(&1.iri == "urn:ash-pplan:workflow:w#a"))
      assert Enum.any?(plan.steps, &(&1.iri =~ "#b" and hd(&1.predecessors) =~ ~r/#a$/))
    end
  end
end

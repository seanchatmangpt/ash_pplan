defmodule AshPPlan.HTNTest do
  use ExUnit.Case, async: true

  alias AshPPlan.HTN
  alias AshPPlan.HTN.{Action, Method}

  describe "HTN hierarchical decomposition and backtracking" do
    test "decomposes compound tasks via precondition-admitted methods and backtracks when downstream primitive fails" do
      actions = [
        Action.new(
          name: :ingest_wo,
          preconditions: [:tenant_bound],
          add_list: [:wo_ingested],
          cost: 1.0
        ),
        Action.new(
          name: :verify_nh3_serial,
          preconditions: [:wo_ingested, :nh3_serial_present],
          add_list: [:nh3_verified],
          cost: 2.0
        ),
        Action.new(
          name: :dispatch_vendor,
          preconditions: [:nh3_verified],
          add_list: [:dispatched],
          cost: 3.0
        ),
        Action.new(
          name: :request_nte_increase,
          preconditions: [:dispatched, :over_nte],
          add_list: [:nte_approved],
          delete_list: [:over_nte],
          cost: 5.0
        ),
        Action.new(
          name: :complete_repair,
          preconditions: [:dispatched],
          add_list: [:repair_completed],
          cost: 4.0
        ),
        Action.new(
          name: :settle_within_nte,
          preconditions: [:repair_completed, :within_nte],
          add_list: [:settled],
          cost: 1.0
        ),
        Action.new(
          name: :settle_with_change_order,
          preconditions: [:repair_completed, :nte_approved],
          add_list: [:settled],
          cost: 2.0
        )
      ]

      methods = [
        Method.new(
          id: :resolve_wo_standard,
          task: :resolve_work_order,
          preconditions: [:tenant_bound],
          priority: 10,
          subtasks: [
            :ingest_wo,
            :verify_nh3_serial,
            :dispatch_vendor,
            :complete_repair,
            :settle_within_nte
          ]
        ),
        Method.new(
          id: :resolve_wo_nte_escalation,
          task: :resolve_work_order,
          preconditions: [:tenant_bound, :over_nte],
          priority: 5,
          subtasks: [
            :ingest_wo,
            :verify_nh3_serial,
            :dispatch_vendor,
            :request_nte_increase,
            :complete_repair,
            :settle_with_change_order
          ]
        )
      ]

      domain = AshPPlan.htn_domain(actions, methods)

      # Case 1: within NTE -> selects :resolve_wo_standard directly
      {:ok, std_result} =
        AshPPlan.htn_plan(
          domain,
          [:resolve_work_order],
          [:tenant_bound, :nh3_serial_present, :within_nte],
          goal_state: [:settled]
        )

      assert std_result.status == :solved
      assert std_result.authority_ceiling == :none

      assert std_result.plan == [
               :ingest_wo,
               :verify_nh3_serial,
               :dispatch_vendor,
               :complete_repair,
               :settle_within_nte
             ]

      assert std_result.total_cost == 11.0
      assert MapSet.member?(std_result.final_state, :settled)

      # Case 2: over NTE -> tries higher-priority :resolve_wo_standard first, fails on
      # :settle_within_nte precondition (:within_nte), backtracks to :resolve_wo_nte_escalation!
      {:ok, esc_result} =
        AshPPlan.htn_plan(
          domain,
          [:resolve_work_order],
          [:tenant_bound, :nh3_serial_present, :over_nte],
          goal_state: [:settled]
        )

      assert esc_result.status == :solved

      assert esc_result.plan == [
               :ingest_wo,
               :verify_nh3_serial,
               :dispatch_vendor,
               :request_nte_increase,
               :complete_repair,
               :settle_with_change_order
             ]

      assert esc_result.total_cost == 17.0
      assert MapSet.member?(esc_result.final_state, :nte_approved)
      assert MapSet.member?(esc_result.final_state, :settled)

      # Anti-vacuity falsifier: remove :nh3_serial_present -> both methods fail on :verify_nh3_serial
      assert {:error, %{reason: :preconditions_not_met, task: :verify_nh3_serial}} =
               AshPPlan.htn_plan(
                 domain,
                 [:resolve_work_order],
                 [:tenant_bound, :within_nte],
                 goal_state: [:settled]
               )
    end
  end

  describe "STRIPS state-space planner (Ex4pmEngine.Cognition.Planner parity)" do
    test "finds shortest action sequence from initial_state to goal_state and refuses unreachable goals" do
      actions = [
        Action.new(name: :authenticate, preconditions: [], add_list: [:authenticated], cost: 1.0),
        Action.new(
          name: :authorize,
          preconditions: [:authenticated],
          add_list: [:authorized],
          cost: 2.0
        ),
        Action.new(
          name: :capture_funds,
          preconditions: [:authorized],
          add_list: [:funds_captured],
          cost: 3.0
        )
      ]

      {:ok, res} =
        HTN.plan(
          MapSet.new(),
          MapSet.new([:funds_captured]),
          actions
        )

      assert res.planning_type == :strips
      assert res.plan == [:authenticate, :authorize, :capture_funds]
      assert res.total_cost == 6.0
      assert res.authority_ceiling == :none

      # Falsifier: unreachable goal
      assert {:error, :no_plan_found} =
               HTN.plan(
                 MapSet.new(),
                 MapSet.new([:impossible_fact]),
                 actions
               )
    end
  end

  describe "Workflow Model to HTN projection and HDDL solve" do
    test "converts AshPPlan.Workflow.Model into an executable HTN and solves HDDL projection" do
      {:ok, wf} =
        AshPPlan.Workflow.Model.new(
          name: "ServEngineDispatch",
          goal: "ServEngineDispatch",
          tasks: [
            [id: :ingest, capability: "ServEngine.Ingest", depends_on: []],
            [id: :match_vendor, capability: "ServEngine.Match", depends_on: [:ingest]],
            [id: :dispatch, capability: "ServEngine.Dispatch", depends_on: [:match_vendor]]
          ],
          methods: [
            [
              id: :m_full_dispatch,
              task: :execute_dispatch,
              precondition: :tenant_active,
              subtasks: [:ingest, :match_vendor, :dispatch]
            ]
          ]
        )

      {:ok, htn, root_tasks} = AshPPlan.htn_from_workflow(wf)
      assert root_tasks == [:execute_dispatch]

      {:ok, solved} = AshPPlan.htn_plan(htn, root_tasks, [:tenant_active])
      assert solved.plan == [:ingest, :match_vendor, :dispatch]
      assert MapSet.member?(solved.final_state, {:completed, :dispatch})

      # Falsifier: missing :tenant_active precondition on method :m_full_dispatch
      assert {:error, %{reason: :no_applicable_method, task: :execute_dispatch}} =
               AshPPlan.htn_plan(htn, root_tasks, [])

      # Project workflow to HDDL and solve via hddl_solve
      {:ok, hddl_text} = AshPPlan.workflow_project(wf, :hddl)

      {:ok, hddl_res} =
        AshPPlan.hddl_solve(hddl_text, "(define (problem p) (:domain ServEngineDispatch))", nil,
          engine: :native,
          allow_stub_problem: true,
          initial_state: ["tenant_active"]
        )

      assert hddl_res.status == :solved
      assert hddl_res.authority_ceiling == :none
    end
  end

  describe "HDDL problem files: parse, ground, native solve" do
    @domain_file Path.join(["planning", "archive", "ash_pplan_v26_9_6.hddl"])
    @problem_file Path.join(["planning", "archive", "ship_v26_9_6.hddl"])

    test "parses the real ship_v26_9_6 problem file into problem data" do
      assert {:ok, problem} =
               @problem_file
               |> File.read!()
               |> AshPPlan.Workflow.Project.HDDL.parse()

      assert problem.problem == "ship-ash-pplan-v26-9-6"
      assert problem.domain == "ash-pplan-v26-9-6"
      assert {"project-exists", "ash-pplan"} in problem.init
      assert {"deliver-release", "ash-pplan", "v26-9-6"} in problem.htn
      assert {"released", "ash-pplan", "v26-9-6"} in problem.goal
    end

    test "grounds and natively solves the real archive domain + ship problem, goal-satisfied" do
      {:ok, res} =
        AshPPlan.hddl_solve(File.read!(@domain_file), File.read!(@problem_file), nil,
          engine: :native
        )

      assert res.status == :solved
      assert res.authority_ceiling == :none
      assert res.problem_file_used == true

      p = "ash-pplan"
      r = "v26-9-6"

      assert res.plan == [
               {"mark-discovered", p},
               {"mark-specified", p},
               {"mark-projected", p},
               {"mark-manufactured", p},
               {"mark-verified", p},
               {"mark-packaged", p, r},
               {"mark-released", p, r},
               {"mark-observed", p, r},
               {"mark-receipted", p, r}
             ]

      for goal <- [
            {"released", p, r},
            {"observed", p, r},
            {"receipted", p, r}
          ] do
        assert MapSet.member?(res.final_state, goal)
      end
    end

    test "refuses a content-less stub problem fail-closed; allow_stub_problem admits it with problem_file_used: false" do
      {:ok, hddl_text} =
        AshPPlan.workflow_project(
          elem(
            AshPPlan.Workflow.Model.new(
              name: "stub_wf",
              goal: "stub_wf",
              tasks: [[id: :only_task, capability: "C", depends_on: []]],
              methods: []
            ),
            1
          ),
          :hddl
        )

      assert {:error, %{reason: :invalid_problem_file}} =
               AshPPlan.hddl_solve(hddl_text, "(define (problem p) (:domain wf-stub_wf))", nil,
                 engine: :native
               )

      {:ok, res} =
        AshPPlan.hddl_solve(hddl_text, "(define (problem p) (:domain wf-stub_wf))", nil,
          engine: :native,
          allow_stub_problem: true
        )

      assert res.status == :solved
      assert res.problem_file_used == false
    end

    test "refuses an unparseable problem file with a typed invalid_problem_file" do
      assert {:error, %{reason: :invalid_problem_file}} =
               AshPPlan.hddl_solve("(define (domain d))", "(define (problem p) (:domain", nil,
                 engine: :native
               )
    end

    test "refuses unsupported precondition forms with a typed parse error (never silent [])" do
      bad_domain = """
      (define (domain bad-pre)
        (:action a :parameters () :precondition (not (foo)) :effect (and (d-a))))
      """

      assert {:error, %{reason: :hddl_parse_error, unsupported_precondition: {:list, ["not", _]}}} =
               AshPPlan.Workflow.Project.HDDL.parse(bad_domain)
    end

    test "parses every real planning/*.hddl domain fixture" do
      domain_files = [
        "planning/ash_pplan_control_plane.hddl",
        "planning/fond_differential.hddl",
        "planning/archive/ash_pplan_v26_9_6.hddl",
        "planning/archive/ash_pplan_v26_9_7.hddl",
        "planning/examples/selfhost.hddl",
        "planning/examples/ontology_only.hddl",
        "planning/examples/qualified_fulfillment.hddl",
        "planning/examples/file_release.hddl",
        "planning/examples/ultracode.hddl"
      ]

      for file <- domain_files do
        text = File.read!(file)
        assert {:ok, _parsed} = AshPPlan.Workflow.Project.HDDL.parse(text), "failed: #{file}"
      end
    end
  end

  describe "decomposition bounds: depth counts method expansion, steps bound, cycles" do
    test "max_depth counts only method-expansion depth (long primitive chains solve at depth 1)" do
      n = 10
      tasks = Enum.map(1..n, &:"t#{&1}")

      actions =
        Enum.map(Enum.with_index(tasks, 1), fn {name, i} ->
          pre = if i == 1, do: [], else: [:"t#{i - 1}"]
          Action.new(name: name, preconditions: pre, add_list: [name])
        end)

      method = Method.new(id: :m_chain, task: :chain, subtasks: tasks)
      domain = AshPPlan.htn_domain(actions, [method])

      {:ok, res} = AshPPlan.htn_plan(domain, [:chain], [], max_depth: 1)
      assert res.plan == tasks
    end

    test "max_steps bounds runaway decomposition with a typed refusal" do
      n = 10
      tasks = Enum.map(1..n, &:"t#{&1}")

      actions =
        Enum.map(Enum.with_index(tasks, 1), fn {name, i} ->
          pre = if i == 1, do: [], else: [:"t#{i - 1}"]
          Action.new(name: name, preconditions: pre, add_list: [name])
        end)

      method = Method.new(id: :m_chain, task: :chain, subtasks: tasks)
      domain = AshPPlan.htn_domain(actions, [method])

      assert {:error, %{reason: :max_steps_exceeded, steps: steps}} =
               AshPPlan.htn_plan(domain, [:chain], [], max_steps: 5)

      assert steps == 5
    end

    test "a cyclic method decomposition terminates with :cyclic_decomposition" do
      action = Action.new(name: :tick, preconditions: [], add_list: [:tocked])
      method = Method.new(id: :m_loop, task: :loop, subtasks: [:tock, :loop])
      tick_method = Method.new(id: :m_tock, task: :tock, subtasks: [:tick])
      domain = AshPPlan.htn_domain([action], [method, tick_method])

      assert {:error, %{reason: :cyclic_decomposition, task: :loop}} =
               AshPPlan.htn_plan(domain, [:loop], [])
    end
  end

  describe "cyclic workflow methods are a typed refusal" do
    test "htn_from_workflow refuses methods with no root task" do
      {:ok, wf} =
        AshPPlan.Workflow.Model.new(
          name: "cyclic_wf",
          goal: "cyclic_wf",
          tasks: [
            [id: :a, capability: "C", depends_on: []],
            [id: :b, capability: "C", depends_on: []]
          ],
          methods: [
            [id: :m_a, task: :a, subtasks: [:b]],
            [id: :m_b, task: :b, subtasks: [:a]]
          ]
        )

      assert {:error, %{reason: :cyclic_methods, tasks: tasks}} = AshPPlan.htn_from_workflow(wf)
      assert Enum.sort(tasks) == [:a, :b]
    end
  end
end

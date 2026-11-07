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
          initial_state: ["tenant_active"]
        )

      assert hddl_res.status == :solved
      assert hddl_res.authority_ceiling == :none
    end
  end
end

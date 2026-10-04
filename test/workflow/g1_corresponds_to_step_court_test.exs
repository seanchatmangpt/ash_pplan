defmodule AshPPlan.Workflow.G1CorrespondsToStepCourtTest do
  @moduledoc """
  G1 Court: `p-plan:correspondsToStep` emission on execution receipts.

  Falsifies: a real workflow run whose receipt prov carries a
  `p-plan:correspondsToStep` count that does not equal the number of executed
  tasks (IRI form must match `AshPPlan.Workflow.Project.Reactor.step_iri/2`),
  or a receipt that emits step correspondence when no step data was supplied
  (honest absence). Anti-vacuity mutation: removing a task from the model must
  change the emitted count.

  Real runtime, real providers (`Steps.Local`), ETS-backed durable store where
  the durable path is exercised. No mocks.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.ExecutionReceipt
  alias AshPPlan.Providers.DurableGate
  alias AshPPlan.Examples.UltraCode.Steps
  alias AshPPlan.Providers.Registry
  alias AshPPlan.Reactor.Durable.{Clock, Store.Ets}
  alias AshPPlan.Workflow.{Evidence, Model, Project.Reactor, Runtime}

  @frontier [
    %{id: :a, status: :open, deps: []},
    %{id: :b, status: :open, deps: [:a]}
  ]

  @p_plan_step "http://purl.org/net/p-plan#correspondsToStep"

  defp model(n_tasks) do
    tasks =
      for i <- 1..n_tasks do
        [
          id: String.to_atom("t#{i}"),
          capability: "Work.Observe",
          after: if(i == 1, do: [], else: [:"t#{i - 1}"]),
          authority: :observe
        ]
      end

    {:ok, m} = Model.new(name: :g1_wf, tasks: tasks)
    m
  end

  defp count_steps(prov) do
    prov |> String.split("\n") |> Enum.count(&String.contains?(&1, @p_plan_step))
  end

  defp step_iris(model) do
    for t <- model.tasks, do: AshPPlan.Workflow.Project.Reactor.step_iri(model, t.id)
  end

  test "a real multi-task run emits one correspondsToStep per executed task" do
    assert {:ok, s} =
             Runtime.run(Steps.workflow(), %{frontier: @frontier}, providers: [Steps.Local])

    assert s.observation.state == :succeeded
    prov = s.evidence.prov
    assert count_steps(prov) == length(Steps.workflow()[:tasks])

    wf = Steps.workflow()
    {:ok, wf_model} = Model.new(wf)

    for t <- wf[:tasks] do
      iri = Reactor.step_iri(wf_model, t[:id])
      assert prov =~ ~s(<#{@p_plan_step}> <#{iri}>)
    end
  end

  test "durable ETS run emits correspondence on the resumed receipt" do
    on_exit(&Clock.reset/0)
    Clock.use_test_clock()

    gated_wf = gated_workflow()

    {:ok, store} = Ets.start_link()

    assert {:ok, s1} =
             Runtime.run(gated_wf, %{frontier: @frontier},
               providers: [Steps.Local, DurableGate],
               store: store,
               run_id: "g1-durable"
             )

    assert s1.observation.state == :halted
    {:ok, e1} = Runtime.explain(s1)
    assert [wait] = e1.durable.waiting_on

    assert {:ok, s2} = Runtime.resume(s1, signal: {wait, %{released: true}})
    assert s2.observation.state == :succeeded

    prov = s2.evidence.prov
    assert count_steps(prov) == length(gated_wf[:tasks])
    assert prov =~ "urn:ash-pplan:workflow:ultracode#step-gate"
  end

  defp gated_workflow do
    base = Steps.workflow()

    tasks =
      Enum.map(base[:tasks], fn t ->
        if t[:id] == :execute, do: Keyword.put(t, :after, [:select, :gate]), else: t
      end)

    Keyword.put(
      base,
      :tasks,
      List.insert_at(tasks, 2,
        id: :gate,
        capability: "Human.Approve",
        after: [:select],
        authority: :observe
      )
    )
  end

  test "honest absence: no step data emits none" do
    # to_rdf/1 without the option emits no step triple
    receipt = observe_receipt("r1")
    refute ExecutionReceipt.to_rdf(receipt) =~ @p_plan_step

    # an empty list also emits none
    refute ExecutionReceipt.to_rdf(observe_receipt("r2"), corresponds_to_steps: []) =~
             @p_plan_step

    # Evidence.bind without the key: none emitted
    m = model(2)
    {:ok, ev} = Evidence.bind(m, run_id: "no-steps")
    refute ev.prov =~ @p_plan_step
  end

  test "anti-vacuity: removing a task from the model breaks the count" do
    {:ok, s3} = run_state(3)
    {:ok, s2} = run_state(2)

    assert count_steps(s3.evidence.prov) == 3
    assert count_steps(s2.evidence.prov) == 2
    assert step_iris(model(3)) -- step_iris(model(2)) != []
  end

  defp run_state(n) do
    m = model(n)
    {:ok, p} = Runtime.plan(m)
    {:ok, r} = Runtime.resolve(m, providers: [Steps.Local])

    state =
      Map.merge(%{model: m, attempt: 1}, Map.take(r, [:registry, :bindings, :resolutions]))

    {:ok, s} = Runtime.observe(state, {:ok, %{}}, [])
    {:ok, s}
  end

  # --- Direct execution path (AshPPlan.execute/4 -> do_execute/5) -----------

  @direct_plan "https://w3id.org/ash-pplan#SubscriptionRenewal"
  @direct_authorize "https://w3id.org/ash-pplan#AuthorizePayment"
  @direct_renew "https://w3id.org/ash-pplan#RenewSubscription"
  @direct_ok_step AshPPlan.Workflow.G1CorrespondsToStepCourtTest.OkStep

  defmodule OkStep do
    # `Reactor.Step` unqualified would resolve to the aliased
    # AshPPlan.Workflow.Project.Reactor.Step, not the Reactor dep.
    use Elixir.Reactor.Step

    @impl true
    def run(_arguments, _context, _options), do: {:ok, :ok}
  end

  test "direct execute path emits one correspondsToStep per handler" do
    handlers = %{@direct_authorize => @direct_ok_step, @direct_renew => @direct_ok_step}

    assert {{:ok, _}, receipt} =
             AshPPlan.execute(@direct_plan, handlers, %{}, %{}, run_id: "g1-direct")

    prov = ExecutionReceipt.to_rdf(receipt)

    for step_iri <- Map.keys(handlers) do
      assert prov =~ ~s(<#{@p_plan_step}> <#{step_iri}>)
    end

    assert count_steps(prov) == map_size(handlers)
  end

  test "direct execute path with empty handlers emits zero step triples" do
    # Honest absence on the direct path is structural: the compiler refuses
    # (missing_handlers) before any execution, so no receipt exists that could
    # carry a step claim. Zero receipts, zero triples.
    assert {:error, %AshPPlan.Compiler.Error{reason: :missing_handlers}} =
             AshPPlan.execute(@direct_plan, %{}, %{}, %{}, run_id: "g1-direct-empty")
  end

  test "direct execute anti-vacuity: dropping a handler breaks the count equality" do
    full = %{@direct_authorize => @direct_ok_step, @direct_renew => @direct_ok_step}
    dropped = Map.delete(full, @direct_renew)

    assert {{:ok, _}, r_full} =
             AshPPlan.execute(@direct_plan, full, %{}, %{}, run_id: "g1-anti-full")

    # With a handler dropped the compiler refuses (missing_handlers), so the
    # handler-count/triple-count equality that held above cannot hold: the
    # mutation kills the execution instead of degrading the receipt.
    assert {:error, %AshPPlan.Compiler.Error{reason: :missing_handlers}} =
             AshPPlan.compile_plan(@direct_plan, dropped)

    prov = ExecutionReceipt.to_rdf(r_full)
    assert count_steps(prov) == map_size(full)
    assert Map.keys(full) -- Map.keys(dropped) != []
  end

  defp observe_receipt(run_id) do
    ExecutionReceipt.observe(
      "urn:ash-pplan:workflow:x",
      run_id,
      {:ok, %{}},
      DateTime.utc_now(),
      System.monotonic_time(:microsecond)
    )
  end
end

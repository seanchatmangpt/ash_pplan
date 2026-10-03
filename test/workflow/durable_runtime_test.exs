defmodule AshPPlan.Workflow.DurableRuntimeTest do
  @moduledoc """
  End-to-end court for the `AshPPlan.Workflow.Runtime` facade over the native durable engine.

  A human-release gate (`Human.Approve`, realized by the generated `durable_gate` provider
  through the `:durable` adapter) is spliced into the UltraCode workflow between select and
  execute. Real Reactor, real ETS ledger. Asserts: plan -> resolve -> start -> attempt parks on
  the gate (`:halted`, ledger `waiting`), `signal` + `resume` completes with checkpoints
  replayed, `explain/1` reports status / waiting-on / checkpoint tape, observation maps ledger
  checkpoints to subject-bound process evidence, and explicit failover re-resolves only the
  failed task while completed (parked-before) tasks are not re-bound.

  Anti-vacuity: resuming without a signal stays halted with the same waiter; the failover
  with an unsealed registry re-selects the failing provider (mutating `seal_failed` to a no-op
  fails the failover assertions).
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Providers.DurableGate
  alias AshPPlan.Examples.UltraCode.Steps
  alias AshPPlan.Providers.Registry
  alias AshPPlan.Reactor.Durable.{Clock, Engine}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Reactor.Middleware.Observation
  alias AshPPlan.Workflow.Runtime

  @frontier [%{id: :a, status: :open, deps: []}, %{id: :b, status: :open, deps: [:a]}]

  setup do
    Clock.use_test_clock()
    on_exit(&Clock.reset/0)
    {:ok, store} = Ets.start_link()
    {:ok, store: store}
  end

  defp gated do
    base = Steps.workflow()

    tasks =
      Enum.map(base[:tasks], fn t ->
        if t[:id] == :execute, do: Keyword.put(t, :after, [:select, :gate]), else: t
      end)

    gate = [id: :gate, capability: "Human.Approve", after: [:select], authority: :observe]
    Keyword.put(base, :tasks, List.insert_at(tasks, 2, gate))
  end

  test "plan -> resolve -> start -> attempt -> halt on release -> signal -> complete",
       %{store: store} do
    providers = [Steps.Local, DurableGate]
    assert {:ok, %{plan: _}} = Runtime.plan(gated())

    assert {:ok, %{bindings: %{gate: %{provider: :durable_gate}}}} =
             Runtime.resolve(gated(), providers: providers)

    assert {:ok, s1} =
             Runtime.run(gated(), %{frontier: @frontier},
               providers: providers,
               store: store,
               run_id: "drt-1"
             )

    assert s1.observation.state == :halted
    assert s1.observation.transition == %{from: :running, action: :execute, to: :halted}
    assert %{status: status} = Engine.fetch(store, "drt-1")
    assert status in [:waiting, :polling]

    {:ok, e1} = Runtime.explain(s1)
    assert e1.durable.status == status
    assert e1.durable.waiting_on != []
    assert length(e1.durable.checkpoints) == 2

    # anti-vacuity: resuming without the signal stays parked on the same waiter
    assert {:ok, s_still} = Runtime.resume(s1)
    assert s_still.observation.state == :halted
    assert {:ok, e_still} = Runtime.explain(s_still)
    assert e_still.durable.waiting_on == e1.durable.waiting_on

    [wait] = e1.durable.waiting_on
    assert {:ok, s2} = Runtime.resume(s1, signal: {wait, %{released: true}})
    assert s2.observation.state == :succeeded
    assert {:ok, %{verified: true}} = s2.outcome
    assert :ok = AshPPlan.Workflow.Evidence.verify(s2.evidence, s2.subject.id)

    {:ok, e2} = Runtime.explain(s2)
    assert e2.durable.status == :completed
    assert e2.durable.waiting_on == []
    assert length(e2.durable.checkpoints) == 6

    # ledger checkpoints map to subject-bound process evidence
    ctx = %{durable: %{store: store, store_module: Ets, run_id: "drt-1"}}
    events = Observation.ledger_events(ctx, s2.subject.id)
    assert length(events) == 6

    assert Enum.all?(
             events,
             &(&1.subject_id == s2.subject.id and &1.activity == "task_checkpointed")
           )
  end

  test "failover after release re-resolves only the failed task", %{store: store} do
    providers = [Steps.Flaky, Steps.Local, DurableGate]

    {:ok, s1} =
      Runtime.run(gated(), %{frontier: @frontier},
        providers: providers,
        store: store,
        run_id: "drt-2"
      )

    assert s1.observation.state == :halted
    [wait] = (Runtime.explain(s1) |> elem(1)).durable.waiting_on

    {:ok, s2} = Runtime.resume(s1, signal: {wait, %{released: true}})
    assert s2.observation.state == :failed
    assert s2.observation.failed_task == :execute
    assert s2.observation.sealed == Steps.Flaky
    assert %{status: :failed} = Engine.fetch(store, "drt-2")

    {:ok, e2} = Runtime.explain(s2)
    assert e2.durable.status == :failed
    assert e2.failure.sealed == Steps.Flaky

    # explicit failover: new run over merged bindings; the gate is re-awaited, signal again
    assert {:ok, s3} = Runtime.resume(s2)
    assert s3.run_id == "drt-2-a2"
    assert s3.attempt == 2
    assert s3.bindings[:execute].provider == :ultracode_local

    for id <- [:observe, :select, :gate, :integrate, :verify] do
      assert s3.bindings[id] == s1.bindings[id]
    end

    assert s3.observation.state == :halted
    [wait3] = (Runtime.explain(s3) |> elem(1)).durable.waiting_on
    assert {:ok, s4} = Runtime.resume(s3, signal: {wait3, %{released: true}})
    assert s4.observation.state == :succeeded
    assert %{status: :completed} = Engine.fetch(store, "drt-2-a2")
    assert %{status: :failed} = Engine.fetch(store, "drt-2")
  end

  test "anti-vacuity: an unsealed registry re-selects the failing provider", %{store: store} do
    {:ok, s1} =
      Runtime.run(gated(), %{frontier: @frontier},
        providers: [Steps.Flaky, Steps.Local, DurableGate],
        store: store,
        run_id: "drt-3"
      )

    [wait] = (Runtime.explain(s1) |> elem(1)).durable.waiting_on
    {:ok, s2} = Runtime.resume(s1, signal: {wait, true})
    unsealed = %{s2 | registry: Registry.new([Steps.Flaky, Steps.Local, DurableGate])}
    assert {:ok, s3} = Runtime.resume(unsealed)
    assert s3.bindings[:execute].provider == :ultracode_flaky
  end

  test "cancel while parked unwinds the run and is terminal", %{store: store} do
    {:ok, s1} =
      Runtime.run(gated(), %{frontier: @frontier},
        providers: [Steps.Local, DurableGate],
        store: store,
        run_id: "drt-4"
      )

    assert s1.observation.state == :halted
    assert {:ok, s2} = Runtime.cancel(s1)
    assert s2.observation.state == :failed
    assert s2.observation.sealed == nil
    assert %{status: :cancelled} = Engine.fetch(store, "drt-4")

    # terminal: a second cancel is a typed refusal, and resume has no failed task to fail over
    assert {:error, %{reason: :not_cancellable}} = Runtime.cancel(s2)
    assert {:error, %{reason: :not_resumable}} = Runtime.resume(s2)
    assert {:error, %{reason: :not_a_durable_run}} = Runtime.cancel(%{})
  end
end

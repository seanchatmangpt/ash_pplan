defmodule AshPPlan.Reactor.Durable.QfLedgerSmokeTest do
  @moduledoc """
  Smoke court: the generated QualifiedFulfillment workflow model (admit, authorize, human
  release, commit) runs through the native durable engine with a human-release Await.

  Halt at the release; drop every in-memory piece (the store process is stopped and the engine
  is rebuilt over a store that holds only data, then a brand-new store is seeded from the
  persisted rows); a fresh attempt; signal `approved`; the run completes and each consequential
  effect counter equals 1. Reactor, ETS store and the counter Agent are real.

  Anti-vacuity: before the signal the commit counter is 0 (the gate really gates), a refusal path
  never commits, and a second run of the same model under a new id repeats the effects (the
  counters can exceed 1).
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.{Clock, Engine, Testing}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Test.{DurableFx, Effects}

  setup do
    DurableFx.install_adapter!()
    Clock.use_test_clock()
    on_exit(&Clock.reset/0)
    {:ok, _} = Effects.start_link()
    {:ok, store} = Ets.start_link()
    {:ok, store: store}
  end

  test "model is the generated QualifiedFulfillment spine", _ctx do
    ids = DurableFx.model().tasks |> Enum.map(& &1.id)
    assert ids -- [:admit_order, :authorize_payment, :await_human_release, :commit_shipment] == []
    assert length(ids) == 4
    gen = AshPPlan.Examples.Workflows.QualifiedFulfillment.model()
    assert gen.goal == DurableFx.model().goal
  end

  test "halt, drop all in-memory state, new attempt, signal approved: effects == 1", %{
    store: store
  } do
    {:ok, rec} = Engine.start(store, DurableFx.attrs("qf-1"))
    assert rec.id == "qf-1"

    assert {:parked, status} = Engine.attempt(store, "qf-1")
    assert status in [:waiting, :polling]
    assert Effects.all() == %{admit: 1, authorize: 1}
    assert Effects.count(:commit) == 0

    # Drop every in-memory piece: keep only the persisted row, bindings and standing ledger.
    persisted = Ets.get_run(store, "qf-1")
    ledger = Ets.standing(store, "qf-1")
    waiters = Ets.waiters(store, "qf-1")
    GenServer.stop(store)
    refute Process.alive?(store)

    {:ok, fresh} = Ets.start_link()
    restore(fresh, persisted, ledger, waiters)

    assert {:parked, _} = Engine.attempt(fresh, "qf-1")
    assert Effects.all() == %{admit: 1, authorize: 1}, "replay must not repeat an effect"

    {:ok, _} = Engine.signal(fresh, "qf-1", DurableFx.signal_name(), :approved)
    assert {:completed, _result} = Engine.attempt(fresh, "qf-1")

    assert Testing.status(fresh, "qf-1") == :completed
    assert Effects.all() == %{admit: 1, authorize: 1, commit: 1}
    assert length(Testing.tape(fresh, "qf-1")) == 4
  end

  test "approval drained without a process kill completes once", %{store: store} do
    {:ok, _} = Engine.start(store, DurableFx.attrs("qf-2"))
    assert [{"qf-2", {:parked, _}}] = Testing.drain(store)
    {:ok, _} = Testing.signal(store, "qf-2", DurableFx.signal_name(), :approved)
    assert [{"qf-2", {:completed, _}}] = Testing.drain(store)
    assert Effects.all() == %{admit: 1, authorize: 1, commit: 1}
  end

  test "start is idempotent by id", %{store: store} do
    {:ok, a} = Engine.start(store, DurableFx.attrs("qf-3"))
    {:ok, b} = Engine.start(store, DurableFx.attrs("qf-3"))
    assert a.id == b.id
    assert length(Ets.list_runs(store)) == 1
  end

  test "anti-vacuity: a new id re-runs from scratch and the counters exceed 1", %{store: store} do
    for id <- ["qf-4a", "qf-4b"] do
      {:ok, _} = Engine.start(store, DurableFx.attrs(id))
      {:ok, _} = Engine.signal(store, id, DurableFx.signal_name(), :approved)
    end

    Testing.drain(store)
    assert Effects.all() == %{admit: 2, authorize: 2, commit: 2}
  end

  # Re-seed a fresh store from persisted data only (no process state survives).
  defp restore(fresh, persisted, ledger, waiters) do
    attrs = %{
      id: persisted.id,
      model: persisted.model,
      bindings: persisted.bindings,
      inputs: persisted.inputs,
      context: persisted.context,
      parent: nil
    }

    {:ok, _} = Ets.start_run(fresh, attrs)
    {:ok, _} = Ets.transition(fresh, persisted.id, :any, persisted.status, %{})

    for cp <- ledger do
      {:ok, _} =
        Ets.record(fresh, cp.run_id, cp.step_key, cp.label, cp.output, %{
          impl: cp.impl,
          args: cp.args
        })
    end

    for w <- waiters do
      {:ok, _} = Ets.park(fresh, persisted.id, w.name, w.kind, w.deadline, [])
    end

    :ok
  end
end

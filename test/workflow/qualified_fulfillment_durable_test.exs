defmodule AshPPlan.Workflow.QualifiedFulfillmentDurableTest do
  @moduledoc """
  Durable park/kill/resume court for the qualified-fulfillment human release, on the native
  ledger engine.

  Real Reactor, real ETS store, real OTP processes. The runner process is killed after the park
  and a fresh runner resumes from the store. Effect counters live in an Agent outside the
  runner; every consequential effect must have executed exactly once. Anti-vacuity: a restart
  that begins a new run (no ledger) double-counts effects, a refused release commits nothing, and
  a terminal run is never re-run.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Examples.QualifiedFulfillment.{Durable, Followup}
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

  test "park, kill, restart, resume approved: no consequential effect repeats", %{store: store} do
    assert {:halted, id} = Durable.run(store, "run-1", "order-7")
    assert Effects.all() == %{admit: 1, authorize: 1}
    assert Testing.status(store, id) in [:waiting, :polling]
    assert length(Testing.tape(store, id)) == 2

    assert {:ok, _} = Durable.resume(store, id, :approved)

    assert Effects.all() == %{admit: 1, authorize: 1, commit: 1}
    assert Testing.status(store, id) == :completed
    assert length(Testing.tape(store, id)) == 4
  end

  test "refused release commits nothing and the run unwinds", %{store: store} do
    {:halted, id} = Durable.run(store, "run-2", "order-8")

    assert {:error, {:release_not_approved, :refused}} = Durable.resume(store, id, :refused)
    assert Effects.count(:commit) == 0
    assert Effects.count(:admit) == 1
    assert Testing.status(store, id) == :cancelled
  end

  test "a terminal run is never re-run", %{store: store} do
    {:halted, id} = Durable.run(store, "run-3", "order-9")
    {:ok, _} = Durable.resume(store, id, :approved)

    assert Engine.attempt(store, id) == :ended
    assert Effects.all() == %{admit: 1, authorize: 1, commit: 1}
  end

  test "anti-vacuity: a restart that starts a new run repeats effects", %{store: store} do
    {:halted, _} = Durable.run(store, "run-4", "order-9")
    {:halted, _} = Durable.run(store, "run-4b", "order-9")
    assert Effects.count(:admit) == 2
  end

  test "followup job carries the run reference and runs the check", %{store: store} do
    {:halted, id} = Durable.run(store, "run-5", "order-11")
    {:ok, _} = Durable.resume(store, id, :approved)

    assert {:ok, %{record: record, job: job}} = Followup.schedule(id)
    assert record.run_ref == id
    assert job.valid?
    assert %{primary_key: _} = Ecto.Changeset.get_field(job, :args)

    assert {:ok, checked} =
             record
             |> Ash.Changeset.for_update(:check_delivery_status, %{}, domain: Followup.Domain)
             |> Ash.update()

    assert checked.checked
    assert checked.run_ref == id
  end
end

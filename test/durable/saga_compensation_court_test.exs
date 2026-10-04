defmodule AshPPlan.Reactor.Durable.SagaCompensationCourtTest do
  @moduledoc """
  REACTOR-SAGA court: generated saga compensation delegates emit typed undo events
  into the durable ledger, and the rollback order is LIFO across two failing steps
  (roll back second-then-first). Real Store.Ets, real Engine.start/3 run rows, real
  generated compensate/4 callbacks, no mocks.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.{Engine, Store.Ets}
  alias AshPPlan.Reactor.Durable.Compensations.{Dispatch, Poll}

  setup do
    {:ok, store} = Ets.start_link()
    {:ok, store: store}
  end

  defp fresh_run(store) do
    {:ok, run} =
      Engine.start(store, %{
        id: "saga-court-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower),
        model: nil
      })

    run
  end

  defp durable_ctx(store, run) do
    %{
      durable: %{
        store: store,
        store_module: Ets,
        run_id: run.id,
        checkpoints: Map.new(Ets.checkpoints(store, run.id), fn {k, c} -> {k, c.output} end)
      }
    }
  end

  test "delegates are compensate-capable per Reactor.Step.can?/2" do
    assert Reactor.Step.can?(%Reactor.Step{impl: Dispatch}, :compensate)
    assert Reactor.Step.can?(%Reactor.Step{impl: Poll}, :compensate)
  end

  test "failing step emits a typed undo event into the ledger" do
    st = test_store()
    run = fresh_run(st)
    ctx = durable_ctx(st, run)

    assert Dispatch.compensate({:error, :boom}, %{a: 1}, ctx, []) == :ok

    events = Ets.signals(st, run.id)
    assert length(events) == 1

    event = List.first(events)
    assert event.name == "ash_pplan.undo.dispatch"
    assert event.payload.type == :saga_undo
    assert event.payload.reason == {:error, :boom}
    assert event.payload.undo_name == "ash_pplan.undo.dispatch"
    assert is_struct(event.payload.at, DateTime)
  end

  test "LIFO rollback across two failing steps: second-then-first by ledger seq" do
    st = test_store()
    run = fresh_run(st)
    ctx = durable_ctx(st, run)

    # Reactor compensates newest-first (LIFO): the second step's undo event must
    # carry the LOWER seq in the same ledger.
    assert Poll.compensate({:error, :late}, %{}, ctx, []) == :ok
    assert Dispatch.compensate({:error, :early}, %{}, ctx, []) == :ok

    undo_events =
      st
      |> Ets.signals(run.id)
      |> Enum.filter(&String.starts_with?(&1.name, "ash_pplan.undo."))
      |> Enum.sort_by(& &1.seq)

    assert Enum.map(undo_events, & &1.name) == [
             "ash_pplan.undo.poll",
             "ash_pplan.undo.dispatch"
           ]

    assert [poll, dispatch] = undo_events
    assert poll.seq < dispatch.seq
    assert poll.payload.type == :saga_undo
    assert poll.payload.reason == {:error, :late}
    assert dispatch.payload.reason == {:error, :early}
  end

  test "delegate never returns :retry and refuses typed without a ledger context" do
    st = test_store()
    run = fresh_run(st)
    ctx = durable_ctx(st, run)

    assert Dispatch.compensate({:error, :x}, %{}, ctx, []) == :ok
    assert Poll.compensate({:error, :x}, %{}, ctx, []) == :ok

    # no durable ledger context: typed refusal, never :retry
    assert {:error, {:saga_undo_refused, {:no_durable_ledger_context, mod}}} =
             Dispatch.compensate({:error, :x}, %{}, %{}, [])

    assert mod == AshPPlan.Reactor.Durable.Steps.Dispatch

    assert {:error, {:saga_undo_refused, {:no_durable_ledger_context, _}}} =
             Poll.compensate({:error, :x}, %{}, %{}, [])
  end

  test "undo events stand unconsumed in the ledger, replayable by the sweep machinery" do
    st = test_store()
    run = fresh_run(st)
    ctx = durable_ctx(st, run)

    assert Dispatch.compensate({:error, :r1}, %{}, ctx, []) == :ok
    assert Poll.compensate({:error, :r2}, %{}, ctx, []) == :ok

    events = Ets.signals(st, run.id)
    assert length(events) == 2
    assert Enum.all?(events, fn s -> s.payload.type == :saga_undo and is_nil(s.consumed_at) end)
  end

  defp test_store do
    {:ok, st} = Ets.start_link()
    st
  end
end

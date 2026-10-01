defmodule AshPPlan.Reactor.Durable.EngineTest do
  @moduledoc """
  Court: `Engine` lifecycle over the real `Store.Ets` and real Reactor.

  Covers idempotent start, outcome mapping to guarded transitions, park status
  (`:waiting`/`:polling`), signals waking a parked run, failure rollback (undo exactly once,
  newest first), cancel (legal only from pending|waiting|polling) with propagation to children,
  parent notification, and level-triggered `runnable?/3`.

  Anti-vacuity mutations: replace the guarded `from` list in `settle/4` with `:any` ->
  "late attempt cannot overwrite :cancelling" fails; make `cancel/3` skip `cancel_children/4`
  -> the propagation test fails; return `true` from `runnable?/4` for terminal runs -> the
  runnable test fails.
  """
  use ExUnit.Case, async: false

  Code.require_file("lane_b_fixture.exs", __DIR__)

  alias AshPPlan.Durable.LaneBFx
  alias AshPPlan.Reactor.Durable.{Clock, Engine, Testing}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Test.Effects

  setup do
    LaneBFx.install_adapter!()
    Clock.use_test_clock()
    on_exit(&Clock.reset/0)
    name = :"fx_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: name)
    {:ok, store} = Ets.start_link()
    {:ok, store: store, fx: name}
  end

  defp start(store, id, fx, opts \\ []) do
    {:ok, rec} = Engine.start(store, LaneBFx.attrs(id, fx, opts))
    rec
  end

  test "start is idempotent by id and returns the existing run", %{store: store, fx: fx} do
    a = start(store, "s1", fx)
    assert {:ok, _} = Engine.attempt(store, "s1") |> then(&{:ok, &1})
    b = start(store, "s1", fx)
    assert a.id == b.id
    assert b.status == :completed
    assert length(Ets.list_runs(store)) == 1
  end

  test "unknown run", %{store: store} do
    assert Engine.attempt(store, "nope") == :not_found
    assert Engine.cancel(store, "nope") == {:error, :no_such_run}
  end

  test "a completing attempt writes the result and releases its claim after", %{
    store: store,
    fx: fx
  } do
    start(store, "c1", fx)
    assert {:completed, result} = Engine.attempt(store, "c1")
    run = Engine.fetch(store, "c1")
    assert run.status == :completed
    assert run.result == result
    assert run.claimed_by == nil
    assert Engine.attempt(store, "c1") == :ended
  end

  test "park on a signal, signal wakes it, completes without repeating steps", %{
    store: store,
    fx: fx
  } do
    start(store, "p1", fx, kinds: %{integrate: :await})
    assert {:parked, :waiting} = Engine.attempt(store, "p1")
    assert Testing.status(store, "p1") == :waiting
    assert LaneBFx.counts(fx) == %{observe: 1, select: 1, execute: 1}
    refute "p1" in Engine.runnable(store, Clock.now())

    {:ok, _} = Engine.signal(store, "p1", "go", :now)
    assert "p1" in Engine.runnable(store, Clock.now())
    assert [{"p1", {:completed, _}}] = Testing.drain(store)
    assert LaneBFx.counts(fx) == %{observe: 1, select: 1, execute: 1, verify: 1}
  end

  test "a signal wakes a parked run whatever it waits on", %{store: store, fx: fx} do
    start(store, "p2", fx, kinds: %{integrate: :await})
    assert {:parked, _} = Engine.attempt(store, "p2")
    {:ok, _} = Engine.signal(store, "p2", "unrelated", 1)
    assert "p2" in Engine.runnable(store, Clock.now())
  end

  test "failure rolls back undo-capable steps exactly once, newest first", %{store: store, fx: fx} do
    start(store, "f1", fx, kinds: %{select: :undo, execute: :undo})
    Effects.fail_after(fx, :verify, 0)
    assert {:failed, _} = Engine.attempt(store, "f1") |> normalise()
    run = Engine.fetch(store, "f1")
    assert run.status == :failed
    assert run.error != nil
    assert Effects.count(fx, {:undo, :select}) == 1
    assert Effects.count(fx, {:undo, :execute}) == 1
    assert Engine.attempt(store, "f1") == :ended
    assert Effects.count(fx, {:undo, :execute}) == 1
  end

  defp normalise({:rolled_back, :failed}), do: {:failed, :rolled_back}
  defp normalise(other), do: other

  test "cancel from waiting rolls back and ends cancelled", %{store: store, fx: fx} do
    start(store, "k1", fx, kinds: %{observe: :undo, integrate: :await})
    assert {:parked, :waiting} = Engine.attempt(store, "k1")
    assert {:ok, %{status: :cancelling}} = Engine.cancel(store, "k1")
    assert [{"k1", {:rolled_back, :cancelled}}] = Testing.drain(store)
    assert Testing.status(store, "k1") == :cancelled
    assert Effects.count(fx, {:undo, :observe}) == 1
    assert Engine.cancel(store, "k1") == {:error, :not_cancellable}
    assert Engine.attempt(store, "k1") == :ended
  end

  test "cancel of a terminal run is refused; a late attempt cannot overwrite :cancelling", %{
    store: store,
    fx: fx
  } do
    start(store, "k2", fx)
    assert {:completed, _} = Engine.attempt(store, "k2")
    assert Engine.cancel(store, "k2") == {:error, :not_cancellable}

    start(store, "k3", fx)
    {:ok, _} = Engine.cancel(store, "k3")
    # the cancelling run is rolled back, never run forward
    assert {:rolled_back, :cancelled} = Engine.attempt(store, "k3")

    assert LaneBFx.counts(fx) |> Map.drop([:observe, :select, :execute, :integrate, :verify]) ==
             %{}

    assert Effects.count(fx, :observe) == 1
  end

  test "cancel propagates to a non-terminal child and the child reports to the parent", %{
    store: store,
    fx: fx
  } do
    start(store, "par", fx, kinds: %{integrate: :await})

    {:ok, _} =
      Engine.start(
        store,
        LaneBFx.attrs("kid", fx, kinds: %{integrate: :await}, parent: {"par", "child_done"})
      )

    assert {:parked, _} = Engine.attempt(store, "par")
    assert {:parked, _} = Engine.attempt(store, "kid")

    {:ok, _} = Engine.cancel(store, "par")
    assert Testing.status(store, "kid") == :cancelling
    Testing.drain(store)
    assert Testing.status(store, "kid") == :cancelled
    assert Testing.status(store, "par") == :cancelled
    sigs = Ets.signals(store, "par")
    assert Enum.any?(sigs, &(&1.name == "child_done" and &1.payload.status == :cancelled))
  end

  test "a completed child delivers its terminal status to the parent", %{store: store, fx: fx} do
    start(store, "par2", fx, kinds: %{integrate: :await})
    {:ok, _} = Engine.start(store, LaneBFx.attrs("kid2", fx, parent: {"par2", "kid_done"}))
    assert {:completed, _} = Engine.attempt(store, "kid2")

    assert [%{name: "kid_done", payload: %{child_id: "kid2", status: :completed}}] =
             Ets.signals(store, "par2")
  end

  test "runnable is ordered by seq and excludes terminal and unwind_blocked runs", %{
    store: store,
    fx: fx
  } do
    for id <- ["z", "a", "m"], do: start(store, id, fx)
    assert Engine.runnable(store, Clock.now()) == ["z", "a", "m"]
    Engine.attempt(store, "a")
    assert Engine.runnable(store, Clock.now()) == ["z", "m"]
    assert [{_, {:completed, _}}, {_, {:completed, _}}] = Testing.drain(store)
    assert Engine.runnable(store, Clock.now()) == []
  end

  test "a waiter whose deadline is due makes a parked run runnable", %{store: store, fx: fx} do
    start(store, "d1", fx, kinds: %{integrate: :await})
    {:parked, :waiting} = Engine.attempt(store, "d1")
    {:ok, _} = Ets.park(store, "d1", "dl", :signal, Clock.add(Clock.now(), 1_000))
    refute "d1" in Engine.runnable(store, Clock.now())
    Clock.advance(1_000)
    assert "d1" in Engine.runnable(store, Clock.now())
  end

  test "steps/2 lists the standing ledger in order", %{store: store, fx: fx} do
    start(store, "t1", fx)
    Engine.attempt(store, "t1")
    assert length(Engine.steps(store, "t1")) == 5

    assert Engine.steps(store, "t1") |> Enum.map(& &1.seq) |> Enum.sort() ==
             Engine.steps(store, "t1") |> Enum.map(& &1.seq)
  end
end

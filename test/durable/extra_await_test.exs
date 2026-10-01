defmodule AshPPlan.Reactor.Durable.ExtraAwaitTest do
  @moduledoc """
  Court (magma-derived): wait steps through the real Engine, not hand-built context.

  Early signal and payload reach the dependent step; a timeout fails the run (`Await` error) or is
  returned tagged (`on_timeout: :return`) and the run completes; the deadline is measured once
  across attempts; a signal for another name wakes a parked run (level-triggered) without
  completing the wait; two independent waits park together and each releases on its own signal;
  a poll wakes on its interval and releases its waiter on success.

  Real Engine, `Store.Ets`, Reactor and test `Clock`. Anti-vacuity mutation (run manually):
  recompute the deadline in `Await.park/7` instead of reading the waiter back -> the "measured once"
  test fails; make `Poll` skip `mod.release/3` on success -> the stale-waiter assertion fails.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.{Clock, Engine, Testing}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Test.{Effects, ExtraFx}

  setup do
    ExtraFx.install_adapter!()
    Clock.use_test_clock(~U[2026-01-01 00:00:00Z])
    on_exit(&Clock.reset/0)
    fx = :"fx_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: fx)
    {:ok, store} = Ets.start_link()
    {:ok, store: store, fx: fx}
  end

  defp start(store, id, fx, extra),
    do: {:ok, _} = Engine.start(store, ExtraFx.attrs(id, fx, extra))

  defp waits(wait), do: %{left: [kind: :await, wait: wait], right: []}

  test "an early signal is taken without ever parking, payload delivered", %{store: s, fx: fx} do
    start(s, "e1", fx, waits(signal: "go", timeout: nil))
    {:ok, _} = Engine.signal(s, "e1", "go", %{n: 1})
    assert {:completed, _} = Engine.attempt(s, "e1")
    assert Enum.any?(Engine.steps(s, "e1"), &(&1.output == %{n: 1}))
    assert Testing.waiting_on(s, "e1") == []
  end

  test "a signal after parking completes the run with the payload", %{store: s, fx: fx} do
    start(s, "e2", fx, waits(signal: "go", timeout: nil))
    assert {:parked, :waiting} = Engine.attempt(s, "e2")
    assert Testing.waiting_on(s, "e2") == ["go"]
    {:ok, _} = Engine.signal(s, "e2", "go", :hello)
    assert [{"e2", {:completed, _}}] = Testing.drain(s)
    assert Enum.any?(Engine.steps(s, "e2"), &(&1.output == :hello))
    assert Testing.waiting_on(s, "e2") == []
  end

  test "timeout as error fails the run; deadline crossed by the clock, never by sleeping",
       %{store: s, fx: fx} do
    start(s, "t1", fx, waits(signal: "go", timeout: 1_000))
    assert {:parked, :waiting} = Engine.attempt(s, "t1")
    refute "t1" in Engine.runnable(s, Clock.now())

    assert [{"t1", outcome}] = Testing.drain(s, advance: :next_deadline)
    assert match?({:failed, _}, outcome) or match?({:rolled_back, :failed}, outcome)
    assert Testing.status(s, "t1") in [:failed, :unwinding]
    assert Effects.count(fx, :join) == 0
  end

  test "timeout with on_timeout: :return records {:timeout, name} and the run completes",
       %{store: s, fx: fx} do
    start(s, "t2", fx, waits(signal: "go", timeout: 500, on_timeout: :return))
    assert {:parked, :waiting} = Engine.attempt(s, "t2")

    assert [{"t2", {:completed, _}}] = Testing.drain(s, advance: :next_deadline)
    assert Enum.any?(Engine.steps(s, "t2"), &(&1.output == {:timeout, "go"}))
    assert Effects.count(fx, :join) == 1
  end

  test "the deadline is measured once across attempts", %{store: s, fx: fx} do
    start(s, "d1", fx, waits(signal: "go", timeout: 1_000))
    assert {:parked, :waiting} = Engine.attempt(s, "d1")
    [w1] = Ets.waiters(s, "d1")
    assert DateTime.compare(w1.deadline, ~U[2026-01-01 00:00:01.000Z]) == :eq

    Clock.advance(400)
    # an unrelated signal wakes the run; the re-attempt parks again on the same waiter
    {:ok, _} = Engine.signal(s, "d1", "other", 1)
    assert {:parked, :waiting} = Engine.attempt(s, "d1")
    [w2] = Ets.waiters(s, "d1")
    assert w2.deadline == w1.deadline
  end

  test "a signal for another name wakes a parked run but does not complete the wait",
       %{store: s, fx: fx} do
    start(s, "o1", fx, waits(signal: "go", timeout: nil))
    assert {:parked, :waiting} = Engine.attempt(s, "o1")
    refute "o1" in Engine.runnable(s, Clock.now())
    {:ok, _} = Engine.signal(s, "o1", "unrelated", 1)
    assert "o1" in Engine.runnable(s, Clock.now())
    assert {:parked, :waiting} = Engine.attempt(s, "o1")
    assert Testing.waiting_on(s, "o1") == ["go"]
    assert Effects.count(fx, :join) == 0
  end

  test "independent waits park together and each releases on its own signal",
       %{store: s, fx: fx} do
    extra = %{
      left: [kind: :await, wait: [signal: "a", timeout: nil]],
      right: [kind: :await, wait: [signal: "b", timeout: nil]]
    }

    start(s, "i1", fx, extra)
    assert {:parked, :waiting} = Engine.attempt(s, "i1")
    assert Enum.sort(Testing.waiting_on(s, "i1")) == ["a", "b"]

    {:ok, _} = Engine.signal(s, "i1", "b", :B)
    assert {:parked, :waiting} = Engine.attempt(s, "i1")
    assert Testing.waiting_on(s, "i1") == ["a"]

    {:ok, _} = Engine.signal(s, "i1", "a", :A)
    assert {:completed, _} = Engine.attempt(s, "i1")
    assert Testing.waiting_on(s, "i1") == []
    assert Effects.count(fx, :join) == 1
  end

  test "a poll parks as :polling, wakes at its interval, releases its waiter on success",
       %{store: s, fx: fx} do
    {:ok, flag} = Agent.start_link(fn -> false end)

    start(s, "p1", fx, %{left: [kind: :poll, flag: flag, wait: [every: 250]]})
    assert {:parked, :polling} = Engine.attempt(s, "p1")
    assert [%{kind: :poll}] = Ets.waiters(s, "p1")
    refute "p1" in Engine.runnable(s, Clock.now())

    Clock.advance(250)
    assert "p1" in Engine.runnable(s, Clock.now())
    # still not satisfied: parks again, deadline refreshed
    assert {:parked, :polling} = Engine.attempt(s, "p1")
    [w] = Ets.waiters(s, "p1")
    assert DateTime.compare(w.deadline, Clock.add(Clock.now(), 250)) == :eq

    Agent.update(flag, fn _ -> true end)
    Clock.advance(250)
    assert {:completed, _} = Engine.attempt(s, "p1")
    assert Ets.waiters(s, "p1") == []
    assert Effects.count(fx, :join) == 1
  end

  test "retention is not required: a completed run keeps answering from its row", %{
    store: s,
    fx: fx
  } do
    start(s, "r1", fx, %{})
    assert {:completed, result} = Engine.attempt(s, "r1")
    run = Engine.fetch(s, "r1")
    assert run.result == result
    assert Engine.attempt(s, "r1") == :ended
    assert Engine.fetch(s, "r1").result == result
  end
end

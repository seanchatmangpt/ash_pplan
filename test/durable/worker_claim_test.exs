defmodule AshPPlan.Reactor.Durable.WorkerClaimTest do
  @moduledoc """
  Court: one attempt at a time per run.

  Four concurrent attempts run each step once; a held claim answers `:taken` and runs nothing;
  a lapsed lease is taken over and the new attempt replays rather than repeats; a crashed
  attempt (its process killed mid-run, claim never released) is resumed without repeating a
  finished step; a terminal run is never re-run.

  Anti-vacuity mutations: remove the `mod.claim/5` call in `claim_and_run/4` -> the concurrent
  test counts > 1 per step; release the claim BEFORE the outcome is written -> a late
  attempt in the concurrent test can re-run; drop `Run.recorded/2` -> the takeover and crash
  tests repeat finished steps.
  """
  use ExUnit.Case, async: false

  Code.require_file("lane_b_fixture.exs", __DIR__)

  alias AshPPlan.Durable.LaneBFx
  alias AshPPlan.Reactor.Durable.{Clock, Engine}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Test.Effects

  setup do
    LaneBFx.install_adapter!()
    Clock.use_test_clock()

    on_exit(fn ->
      Clock.reset()
      :persistent_term.erase({LaneBFx, :victim})
    end)

    name = :"fx_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: name)
    {:ok, store} = Ets.start_link()
    {:ok, store: store, fx: name}
  end

  defp start(store, id, fx, opts \\ []) do
    {:ok, rec} = Engine.start(store, LaneBFx.attrs(id, fx, opts))
    rec
  end

  test "four concurrent attempts run each step once", %{store: store, fx: fx} do
    start(store, "w1", fx, extra: %{execute: [sleep: 60], integrate: [sleep: 60]})

    outcomes =
      1..4
      |> Enum.map(fn _ -> Task.async(fn -> Engine.attempt(store, "w1") end) end)
      |> Task.await_many(15_000)

    assert Enum.count(outcomes, &match?({:completed, _}, &1)) == 1
    assert Enum.all?(outcomes, &(match?({:completed, _}, &1) or &1 in [:taken, :ended]))
    assert LaneBFx.counts(fx) == %{observe: 1, select: 1, execute: 1, integrate: 1, verify: 1}
    assert Engine.fetch(store, "w1").status == :completed
  end

  test "a held claim answers :taken and runs nothing", %{store: store, fx: fx} do
    start(store, "w2", fx)
    {:ok, _} = Ets.claim(store, "w2", "other-worker", 30_000, Clock.now())
    assert Engine.attempt(store, "w2") == :taken
    assert LaneBFx.counts(fx) == %{}
    refute "w2" in Engine.runnable(store, Clock.now())
  end

  test "a lapsed lease is taken over; the new attempt completes the run", %{store: store, fx: fx} do
    start(store, "w3", fx)
    {:ok, _} = Ets.claim(store, "w3", "ghost", 1_000, Clock.now())
    assert Engine.attempt(store, "w3") == :taken
    Clock.advance(2_000)
    assert {:completed, _} = Engine.attempt(store, "w3")
    assert LaneBFx.counts(fx) == %{observe: 1, select: 1, execute: 1, integrate: 1, verify: 1}
  end

  test "a lapsed claim makes the run runnable again", %{store: store, fx: fx} do
    start(store, "w4", fx)
    {:ok, _} = Ets.claim(store, "w4", "ghost", 1_000, Clock.now())
    refute "w4" in Engine.runnable(store, Clock.now())
    Clock.advance(Engine.lease_ms() + 1)
    assert "w4" in Engine.runnable(store, Clock.now())
  end

  test "a crashed attempt is resumed without repeating a finished step", %{store: store, fx: fx} do
    start(store, "w5", fx, kinds: %{integrate: :crash})

    {pid, ref} =
      spawn_monitor(fn ->
        :persistent_term.put({LaneBFx, :victim}, self())
        Engine.attempt(store, "w5")
      end)

    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 10_000
    crashed = Engine.fetch(store, "w5")
    assert crashed.claimed_by != nil
    assert Effects.count(fx, :observe) == 1
    assert Effects.count(fx, :integrate) == 0

    assert Engine.attempt(store, "w5") == :taken
    Clock.advance(Engine.lease_ms() + 1)
    assert {:completed, _} = Engine.attempt(store, "w5")

    assert LaneBFx.counts(fx) |> Map.take([:observe, :select, :execute, :integrate, :verify]) ==
             %{observe: 1, select: 1, execute: 1, integrate: 1, verify: 1}
  end

  test "a terminal run is never re-run", %{store: store, fx: fx} do
    start(store, "w6", fx)
    assert {:completed, _} = Engine.attempt(store, "w6")
    before = LaneBFx.counts(fx)
    assert Engine.attempt(store, "w6") == :ended
    assert Engine.attempt(store, "w6") == :ended
    assert LaneBFx.counts(fx) == before
    assert Engine.runnable(store, Clock.now()) == []
  end

  test "idempotent start by id does not reset a finished run", %{store: store, fx: fx} do
    start(store, "w7", fx)
    {:completed, _} = Engine.attempt(store, "w7")
    again = start(store, "w7", fx)
    assert again.status == :completed
    assert Engine.attempt(store, "w7") == :ended
    assert Effects.count(fx, :verify) == 1
  end
end

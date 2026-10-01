defmodule AshPPlan.Reactor.Durable.AuditRaceSignalUnwindTest do
  @moduledoc """
  Lane a0 adversarial race court: signal consume-once, checkpoint insert-or-adopt and racing
  `Unwind.run/3` under concurrency.

  Anti-vacuity mutations: drop the `consumed_at` guard in `Store.Ets.consume_signal/3` -> the
  consume-once test fails; drop the insert-or-adopt lookup in `Store.Ets.record/6` -> the
  adopt test fails; make `Unwind.drive/5` skip `claim_undo/4` -> the undo-once test fails.
  """

  use ExUnit.Case, async: false

  Code.require_file("lane_b_fixture.exs", __DIR__)

  alias AshPPlan.Durable.LaneBFx
  alias AshPPlan.Reactor.Durable.{Clock, Engine, Unwind}
  alias AshPPlan.Reactor.Durable.Store.Ets

  setup do
    LaneBFx.install_adapter!()
    Clock.use_test_clock()
    on_exit(&Clock.reset/0)

    {:ok, fx} = AshPPlan.Test.Effects.start_link(name: :"sig_fx_#{System.unique_integer()}")
    {:ok, store} = Ets.start_link()
    {:ok, store: store, fx: fx}
  end

  test "a signal is consumed exactly once under K racing consumers", %{store: store} do
    {:ok, _} = Ets.start_run(store, %{id: "s1"})
    {:ok, sig} = Ets.deliver_signal(store, "s1", "go", :payload)

    results =
      1..8
      |> Enum.map(fn _ ->
        Task.async(fn -> Ets.consume_signal(store, sig.id, Clock.now()) end)
      end)
      |> Task.await_many(:infinity)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == :taken)) == 7
  end

  test "K racing writers of one checkpoint key adopt one standing row", %{store: store} do
    {:ok, _} = Ets.start_run(store, %{id: "s2"})

    outputs =
      1..16
      |> Enum.map(fn i ->
        Task.async(fn ->
          Ets.record(store, "s2", "step.key", "step.key", {:out, i}, %{name: :step})
        end)
      end)
      |> Task.await_many(:infinity)

    assert Enum.all?(outputs, &match?({:ok, _}, &1))
    cps = Ets.checkpoints(store, "s2")
    assert map_size(cps) == 1
    # First writer wins: every caller gets the same standing output back.
    assert Enum.uniq(Enum.map(outputs, fn {:ok, cp} -> cp.output end)) == [{:out, 1}]
    assert Enum.uniq(Enum.map(Map.values(cps), & &1.seq)) |> length() == 1
  end

  test "K racing rollbacks undo each effect exactly once", %{store: store, fx: fx} do
    id = "race-unwind-1"

    {:ok, _} =
      Engine.start(
        store,
        LaneBFx.attrs(id, fx,
          kinds: %{observe: :undo, select: :undo, execute: :undo, integrate: :await}
        )
      )

    assert {:parked, :waiting} = Engine.attempt(store, id)
    assert LaneBFx.counts(fx) == %{observe: 1, select: 1, execute: 1}

    # Commit the run to a rollback nobody holds.
    assert {:ok, _} = Ets.transition(store, id, [:waiting], :unwinding, %{})

    results =
      1..4
      |> Enum.map(fn _ -> Task.async(fn -> Unwind.run(store, id, store_module: Ets) end) end)
      |> Task.await_many(30_000)

    # Every racer answers ok (losers find their claims taken).
    assert Enum.all?(results, &match?({:ok, _}, &1))

    # The real undo effects ran exactly once each.
    assert LaneBFx.counts(fx) == %{
             :observe => 1,
             :select => 1,
             :execute => 1,
             {:undo, :observe} => 1,
             {:undo, :select} => 1,
             {:undo, :execute} => 1
           }

    # Every checkpoint is retired.
    assert Ets.standing(store, id) == []
  end
end

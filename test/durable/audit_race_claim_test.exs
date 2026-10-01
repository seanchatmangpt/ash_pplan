defmodule AshPPlan.Reactor.Durable.AuditRaceClaimTest do
  @moduledoc """
  Lane a0 adversarial race court: `claim`/lease/release_claim and `runnable?` under concurrency.

  Anti-vacuity mutation: delete the `leases` bookkeeping in `Store.Ets.claim/5` (make every
  claim succeed) -> `concurrent claim` and `superseded claimer` tests fail; make
  `Engine.held?/3` use the store-recorded lease -> the `runnable?` contradiction test fails.
  """

  use ExUnit.Case, async: false
  alias AshPPlan.Reactor.Durable.{Clock, Engine}
  alias AshPPlan.Reactor.Durable.Store.Ets

  setup do
    Clock.use_test_clock()
    on_exit(&Clock.reset/0)
    {:ok, store} = Ets.start_link()
    {:ok, store: store}
  end

  defp bare_run(store, id) do
    assert {:ok, _} = Ets.start_run(store, %{id: id})
    :ok
  end

  test "exactly one of K concurrent claims wins", %{store: store} do
    bare_run(store, "c1")

    results =
      1..8
      |> Enum.map(fn i ->
        Task.async(fn -> Ets.claim(store, "c1", {:claimer, i}, 60_000, Clock.now()) end)
      end)
      |> Task.await_many(:infinity)

    wins = Enum.filter(results, &match?({:ok, _}, &1))
    assert length(wins) == 1
    assert Enum.count(results, &(&1 == :taken)) == 7
  end

  test "a released claim is gone and a superseded claimer cannot release", %{store: store} do
    bare_run(store, "c2")
    t0 = Clock.now()

    assert {:ok, _} = Ets.claim(store, "c2", :a, 20, t0)
    assert %{claimed_by: :a} = Ets.get_run(store, "c2")

    Clock.advance(60)
    assert {:ok, _} = Ets.claim(store, "c2", :b, 60_000, Clock.now())

    # A's late release must not touch B's claim...
    assert :ok = Ets.release_claim(store, "c2", :a)
    assert %{claimed_by: :b} = Ets.get_run(store, "c2")
    # ...and A cannot re-claim inside B's live lease.
    assert :taken = Ets.claim(store, "c2", :a, 60_000, Clock.now())
  end

  test "defect probe: Engine.runnable? ignores the lease the store recorded", %{store: store} do
    bare_run(store, "c3")
    t0 = Clock.now()

    # Claimer takes a 60s lease; the store records that lease.
    assert {:ok, rec} = Ets.claim(store, "c3", :holder, 60_000, t0)

    later = Clock.advance(40_000)

    # The store knows the run is still held (40s < 60s lease): another claimer is refused.
    assert :taken = Ets.claim(store, "c3", :other, 1_000, later)

    # But Engine.runnable? (default 30s lease assumption) says the run is runnable NOW.
    assert Engine.runnable?(store, rec, later) == true,
           "runnable? says runnable while the recorded 60s lease still holds: " <>
             "scheduler double-attempts a live run (Engine.held?/3 never reads the store lease)"
  end
end

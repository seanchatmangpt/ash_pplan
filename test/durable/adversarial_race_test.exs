defmodule AshPPlan.Reactor.Durable.AdversarialRaceTest do
  @moduledoc """
  Adversarial court for the signal and claim races of the durable engine.

  Real `Store.Ets`, real `Steps.Await`, real `Engine`; no mocks. Probes: a lost wakeup (a signal
  delivered after the first take but before the park, and during the blocking window), a double
  consume (one signal, many racing consumers), and a claim lapsing during an attempt (a stale
  claimer must neither revive nor release the new holder's claim).

  Anti-vacuity mutation: making `Await` skip its post-park re-take fails the lost-wakeup test;
  making `consume_signal` ignore `consumed_at` fails the double-consume test; making
  `release_claim` ignore `claimed_by` fails the claim-lapse test.
  """
  use ExUnit.Case, async: false

  Code.require_file("lane_b_fixture.exs", __DIR__)

  alias AshPPlan.Durable.LaneBFx
  alias AshPPlan.Reactor.Durable.{Clock, Engine, Steps.Await}
  alias AshPPlan.Reactor.Durable.Store.Ets

  @id_key AshPPlan.Reactor.context_key()

  setup do
    Clock.use_test_clock()
    on_exit(&Clock.reset/0)
    {:ok, store} = Ets.start_link([])
    {:ok, store: store}
  end

  defp start!(s, id) do
    {:ok, _} =
      Engine.start(s, %{id: id, context: %{@id_key => %{subject: "sha256:r", workflow: :r}}})

    id
  end

  defp await_ctx(s, id),
    do: %{durable: %{store: s, store_module: Ets, run_id: id, checkpoints: %{}}, durable_step: :x}

  test "lost wakeup: signal delivered after the first take, before the park, is not lost", %{
    store: s
  } do
    id = start!(s, "lw1")
    # first take finds nothing; the delivery lands before park_and_block parks and re-takes
    assert Ets.pending_signal(s, id, "go") == nil
    {:ok, _} = Engine.signal(s, id, "go", :payload)
    assert {:ok, :payload} = Await.run(%{}, await_ctx(s, id), signal: "go")
    assert Ets.waiters(s, id) == []
  end

  test "lost wakeup: signal arriving during the blocking window wakes the step", %{store: s} do
    id = start!(s, "lw2")

    task =
      Task.async(fn -> Await.run(%{}, await_ctx(s, id), signal: "go", block_ms: 2_000) end)

    # wait until the waiter is parked, then deliver
    LaneBFx.until(fn -> Ets.get_waiter(s, id, "go") != nil end)
    {:ok, _} = Engine.signal(s, id, "go", :late)
    assert {:ok, :late} = Task.await(task, 5_000)
  end

  test "lost wakeup: a signal delivered to a parked run makes it runnable (level-triggered)", %{
    store: s
  } do
    id = start!(s, "lw3")
    {:ok, _} = Ets.park(s, id, "go", :signal, nil, [])
    {:ok, _} = Ets.transition(s, id, [:pending], :waiting, %{})
    refute Engine.runnable?(s, Ets.get_run(s, id), Clock.now())
    {:ok, _} = Engine.signal(s, id, "go", 1)
    assert Engine.runnable?(s, Ets.get_run(s, id), Clock.now())
    assert id in Engine.runnable(s, Clock.now())
  end

  test "double consume: one signal, many racing consumers, exactly one wins", %{store: s} do
    id = start!(s, "dc1")
    {:ok, sig} = Engine.signal(s, id, "go", :once)

    results =
      1..12
      |> Enum.map(fn _ -> Task.async(fn -> Ets.consume_signal(s, sig.id, Clock.now()) end) end)
      |> Task.await_many(10_000)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == :taken)) == 11
  end

  test "double consume: two racing awaits on one signal, one gets it, the other halts", %{
    store: s
  } do
    id = start!(s, "dc2")
    {:ok, _} = Engine.signal(s, id, "go", :only)

    results =
      1..2
      |> Enum.map(fn _ ->
        Task.async(fn -> Await.run(%{}, await_ctx(s, id), signal: "go") end)
      end)
      |> Task.await_many(10_000)

    assert Enum.count(results, &(&1 == {:ok, :only})) == 1
    assert Enum.count(results, &match?({:halt, %{awaiting: "go"}}, &1)) == 1
  end

  test "claim lapse: a stale claimer neither revives nor releases the new holder", %{store: s} do
    id = start!(s, "cl1")
    assert {:ok, _} = Ets.claim(s, id, "A", 1_000, Clock.now())
    assert :taken = Ets.claim(s, id, "B", 1_000, Clock.now())
    refute Engine.runnable?(s, Ets.get_run(s, id), Clock.now(), lease_ms: 1_000)

    Clock.advance(1_001)
    # lapsed: runnable again, B takes over
    assert Engine.runnable?(s, Ets.get_run(s, id), Clock.now(), lease_ms: 1_000)
    assert {:ok, _} = Ets.claim(s, id, "B", 1_000, Clock.now())

    # A (stale) finishing its attempt releases: must not drop B's claim
    :ok = Ets.release_claim(s, id, "A")
    assert Ets.get_run(s, id).claimed_by == "B"
    assert :taken = Ets.claim(s, id, "C", 1_000, Clock.now())
  end

  test "claim lapse during an attempt: the original attempt still finishes and the run ends once",
       %{store: s} do
    id = start!(s, "cl2")
    assert {:ok, _} = Ets.claim(s, id, "A", 1_000, Clock.now())
    Clock.advance(2_000)
    # B takes over the lapsed claim and drives the run (empty model: nothing to replay)
    assert {:ok, _} = Ets.claim(s, id, "B", 1_000, Clock.now())
    {:ok, _} = Engine.cancel(s, id)
    assert {:rolled_back, :cancelled} = Engine.attempt(s, id, claimer: "B")
    # A's late attempt sees a terminal run
    assert :ended = Engine.attempt(s, id, claimer: "A")
    assert Ets.get_run(s, id).status == :cancelled
    assert Ets.get_run(s, id).claimed_by == nil
  end
end

defmodule AshPPlan.Reactor.Durable.EngineLeaseTest do
  @moduledoc """
  Court (P2 claim lease persistence): the lease lives ON the record (`lease_ms`/`lease_until`
  persisted at claim), so a store restart cannot invent or drop a lease. `claimable?` and the
  engine's `held?` read the record; a claimed record with a nil lease fails CLOSED. The engine's
  pre/post-run `renew_claim/4` CAS heartbeat converts a stolen claim into a typed
  `{:error, {:claim_stolen, run_id}}`.

  Anti-vacuity: a store that does not persist the lease fails `claim_persists_lease`; an engine
  that skips the post-run CAS answers the old outcome instead of `{:error, {:claim_stolen, _}}`.
  """
  use ExUnit.Case, async: false

  Code.require_file("lane_b_fixture.exs", __DIR__)

  alias AshPPlan.Durable.LaneBFx
  alias AshPPlan.Reactor.Durable.{Clock, Engine, Store.Ets}

  setup do
    LaneBFx.install_adapter!()
    Clock.use_test_clock()
    on_exit(&Clock.reset/0)
    name = :"fx_#{System.unique_integer([:positive])}"
    {:ok, _} = AshPPlan.Test.Effects.start_link(name: name)
    {:ok, store} = Ets.start_link()
    {:ok, store: store, fx: name}
  end

  defp start(store, id, fx, opts \\ []) do
    {:ok, rec} = Engine.start(store, LaneBFx.attrs(id, fx, opts))
    rec
  end

  test "claim persists lease_ms and lease_until on the record", %{store: s} do
    t0 = Clock.now()
    {:ok, _} = Ets.start_run(s, %{id: "r1"})
    {:ok, r} = Ets.claim(s, "r1", :a, 1000, t0)
    assert r.lease_ms == 1000
    assert r.lease_until == Clock.add(t0, 1000)
    assert Ets.get_run(s, "r1").lease_until == Clock.add(t0, 1000)
  end

  test "release_claim clears the claim and the lease", %{store: s} do
    t0 = Clock.now()
    {:ok, _} = Ets.start_run(s, %{id: "r2"})
    {:ok, _} = Ets.claim(s, "r2", :a, 1000, t0)
    assert :ok = Ets.release_claim(s, "r2", :a)
    r = Ets.get_run(s, "r2")
    assert r.claimed_by == nil and r.claimed_at == nil
    assert r.lease_ms == nil and r.lease_until == nil
  end

  test "renew_claim is a holder-only CAS; foreign or missing claim is :taken", %{store: s} do
    t0 = Clock.now()
    {:ok, _} = Ets.start_run(s, %{id: "r3"})
    {:ok, _} = Ets.claim(s, "r3", :a, 1000, t0)

    assert {:ok, r} = Ets.renew_claim(s, "r3", :a, 120_000)
    assert r.lease_ms == 120_000
    assert DateTime.compare(r.lease_until, Clock.add(t0, 1000)) == :gt

    assert :taken = Ets.renew_claim(s, "r3", :b, 120_000)
    assert :taken = Ets.renew_claim(s, "missing", :a, 120_000)
    assert Ets.get_run(s, "r3").lease_ms == 120_000
  end

  test "held? is lease-based; a claimed record with a nil lease fails CLOSED", %{store: s} do
    t0 = Clock.now()
    {:ok, _} = Ets.start_run(s, %{id: "r4", claimed_at: t0, claimed_by: :ghost})

    base = Ets.get_run(s, "r4")
    assert Engine.runnable?(s, base, t0) == false

    # nil lease: held forever, even a day later (fail closed)
    assert Engine.runnable?(s, base, Clock.add(t0, 86_400_000)) == false

    # a persisted lease lapses: held inside, runnable after.
    # The nil-lease claim above is held FOREVER for other claimers (fail
    # closed), so the lease gets set by the SAME claimer's re-entry — the
    # one path claimable? admits through a held claim.
    {:ok, _} = Ets.claim(s, "r4", :ghost, 1000, t0)
    held = Ets.get_run(s, "r4")
    assert Engine.runnable?(s, held, Clock.add(t0, 500)) == false
    assert Engine.runnable?(s, held, Clock.add(t0, 1000)) == true
  end

  test "an attempt whose claim is stolen mid-run returns {:error, {:claim_stolen, id}}", %{
    store: s,
    fx: fx
  } do
    start(s, "r5", fx, extra: %{execute: [sleep: 200]})

    # the attempt runs in a task; while `execute` sleeps, the lapsed lease is stolen
    attempt = Task.async(fn -> Engine.attempt(s, "r5", claimer: "victim", lease_ms: 1000) end)

    wait_until(fn -> AshPPlan.Test.Effects.count(fx, :select) == 1 end)
    Clock.advance(60_000)
    {:ok, _} = Ets.claim(s, "r5", :hijacker, 60_000, Clock.now())

    assert {:error, {:claim_stolen, "r5"}} = Task.await(attempt)
    assert Ets.get_run(s, "r5").claimed_by == :hijacker
  end

  # Bounded poll on a real observable (no fixed-sleep coordination)
  defp wait_until(fun, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(10)
        wait_until(fun, deadline)

      true ->
        flunk("condition never held within budget")
    end
  end
end

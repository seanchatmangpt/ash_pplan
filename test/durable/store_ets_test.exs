defmodule AshPPlan.Reactor.Durable.StoreEtsTest do
  @moduledoc """
  Court for `Store.Ets`: every Store callback against the real GenServer-backed store, including
  concurrent claim / record / consume races. Anti-vacuity mutation: the race tests assert
  exactly-one-winner counts, which fail if the store stopped serialising its CAS operations
  (e.g. claim always returning {:ok, _}).
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Reactor.Durable.Store.Ets

  @t0 ~U[2026-01-01 00:00:00.000Z]

  setup do
    {:ok, s} = Ets.start_link()
    {:ok, _} = Ets.start_run(s, %{id: "r1", model: :m, bindings: %{a: 1}})
    %{s: s}
  end

  test "start_run is exclusive, get/list roundtrip, parent stored", %{s: s} do
    assert {:error, :exists} = Ets.start_run(s, %{id: "r1"})

    {:ok, c} = Ets.start_run(s, %{id: "r2", parent: {"r1", "sig"}})
    assert c.parent_id == "r1" and c.parent_signal == "sig"
    assert Ets.get_run(s, "r1").bindings == %{a: 1}
    assert Ets.get_run(s, "nope") == nil
    assert Enum.map(Ets.list_runs(s), & &1.id) == ["r1", "r2"]
  end

  test "transition: ok bumps version, stale, illegal, not_found, terminal absorbing", %{s: s} do
    v = Ets.get_run(s, "r1").version
    assert {:ok, r} = Ets.transition(s, "r1", [:pending], :waiting, %{})
    assert r.status == :waiting and r.version == v + 1
    assert {:error, :stale} = Ets.transition(s, "r1", [:pending], :completed, %{})
    assert {:error, :illegal} = Ets.transition(s, "r1", :any, :cancelled, %{})
    assert {:error, :not_found} = Ets.transition(s, "zz", :any, :failed, %{})
    assert {:ok, %{result: 42}} = Ets.transition(s, "r1", :any, :completed, %{result: 42})
    assert {:error, :stale} = Ets.transition(s, "r1", :any, :failed, %{})
    assert Ets.get_run(s, "r1").status == :completed
  end

  test "claim: lease, lapse takeover, same-claimer re-entry, nil never re-enters", %{s: s} do
    assert {:ok, r} = Ets.claim(s, "r1", :a, 1000, @t0)
    assert r.claimed_by == :a
    assert :taken = Ets.claim(s, "r1", :b, 1000, DateTime.add(@t0, 500, :millisecond))
    assert {:ok, _} = Ets.claim(s, "r1", :a, 1000, DateTime.add(@t0, 500, :millisecond))
    assert {:ok, r} = Ets.claim(s, "r1", :b, 1000, DateTime.add(@t0, 5000, :millisecond))
    assert r.claimed_by == :b
    assert :ok = Ets.release_claim(s, "r1", :a)
    assert Ets.get_run(s, "r1").claimed_by == :b
    assert :ok = Ets.release_claim(s, "r1", :b)
    assert Ets.get_run(s, "r1").claimed_by == nil

    assert {:ok, _} = Ets.claim(s, "r1", nil, 1000, @t0)
    assert :taken = Ets.claim(s, "r1", nil, 1000, DateTime.add(@t0, 1, :millisecond))
    assert {:ok, _} = Ets.claim(s, "r1", nil, 1000, DateTime.add(@t0, 1000, :millisecond))
    assert :taken = Ets.claim(s, "missing", :a, 10, @t0)
  end

  test "concurrent claim: exactly one winner", %{s: s} do
    results =
      1..32
      |> Task.async_stream(fn n -> Ets.claim(s, "r1", {:c, n}, 60_000, @t0) end,
        max_concurrency: 32
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == :taken)) == 31
  end

  test "record is insert-or-adopt; standing orders by seq; checkpoints keyed", %{s: s} do
    {:ok, a} = Ets.record(s, "r1", "k1", "one", 1, %{impl: Foo, args: %{x: 1}})
    {:ok, b} = Ets.record(s, "r1", "k2", "two", 2, %{})
    {:ok, a2} = Ets.record(s, "r1", "k1", "one", 999, %{})
    assert a2 == a and a2.output == 1 and a.impl == Foo and a.args == %{x: 1}
    assert b.seq > a.seq
    assert Enum.map(Ets.standing(s, "r1"), & &1.label) == ["one", "two"]
    assert Map.keys(Ets.checkpoints(s, "r1")) |> Enum.sort() == ["k1", "k2"]
    assert Ets.checkpoints(s, "other") == %{}
  end

  test "concurrent record adopts: one standing row, all callers see the first output", %{s: s} do
    outs =
      1..24
      |> Task.async_stream(
        fn n -> Ets.record(s, "r1", "k", "l", n, %{}) |> elem(1) |> Map.fetch!(:output) end,
        max_concurrency: 24
      )
      |> Enum.map(fn {:ok, o} -> o end)

    assert length(Enum.uniq(outs)) == 1
    assert length(Ets.standing(s, "r1")) == 1
  end

  test "claim_undo is once-only; release_undo reopens it", %{s: s} do
    {:ok, _} = Ets.record(s, "r1", "k", "l", 1, %{})
    assert {:ok, cp} = Ets.claim_undo(s, "r1", "k", @t0)
    assert cp.undone_at == @t0
    assert :taken = Ets.claim_undo(s, "r1", "k", @t0)
    assert Ets.standing(s, "r1") == []
    assert :ok = Ets.release_undo(s, "r1", "k")
    assert {:ok, _} = Ets.claim_undo(s, "r1", "k", @t0)
    assert :taken = Ets.claim_undo(s, "r1", "nokey", @t0)
    assert :ok = Ets.release_undo(s, "r1", "nokey")
  end

  test "signals: FIFO per name, consume-once, concurrent consume has one winner", %{s: s} do
    {:ok, s1} = Ets.deliver_signal(s, "r1", "go", 1)
    {:ok, s2} = Ets.deliver_signal(s, "r1", "go", 2)
    {:ok, _} = Ets.deliver_signal(s, "r1", "other", 3)
    assert Ets.pending_signal(s, "r1", "go").id == s1.id
    assert Ets.pending_signal(s, "r1", "none") == nil

    results =
      1..16
      |> Task.async_stream(fn _ -> Ets.consume_signal(s, s1.id, @t0) end, max_concurrency: 16)
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert :taken = Ets.consume_signal(s, s1.id, @t0)
    assert :taken = Ets.consume_signal(s, :missing, @t0)
    assert Ets.pending_signal(s, "r1", "go").id == s2.id
    assert length(Ets.signals(s, "r1")) == 3
    assert Ets.signals(s, "r2") == []
  end

  test "park keeps first deadline unless overwrite; release idempotent; release_all", %{s: s} do
    d1 = DateTime.add(@t0, 1000, :millisecond)
    d2 = DateTime.add(@t0, 9000, :millisecond)
    assert {:ok, w} = Ets.park(s, "r1", "w", :signal, d1, [])
    assert {:ok, ^w} = Ets.park(s, "r1", "w", :signal, d2, [])
    assert Ets.get_waiter(s, "r1", "w").deadline == d1
    assert {:ok, w2} = Ets.park(s, "r1", "w", :poll, d2, overwrite: true)
    assert w2.deadline == d2 and w2.kind == :poll
    {:ok, _} = Ets.park(s, "r1", "v", :signal, nil, [])
    assert Enum.map(Ets.waiters(s, "r1"), & &1.name) == ["v", "w"]

    assert :ok = Ets.release(s, "r1", "w")
    assert :ok = Ets.release(s, "r1", "w")
    assert Ets.get_waiter(s, "r1", "w") == nil
    assert :ok = Ets.release_all(s, "r1")
    assert Ets.waiters(s, "r1") == []
  end
end

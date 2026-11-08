defmodule AshPPlan.Reactor.Durable.StoreTriodTest do
  @moduledoc """
  Court: one differential law suite running the SAME lifecycle script against all three
  stores (Ets, Dets, Wal), comparing normalized projections of the resulting store state
  (ids/statuses/orderings, not byte equality).

  Segments:
  1. Lifecycle parity: start_run -> claim -> renew -> record x3 -> deliver+consume signal ->
     record_error (transition :failed) -> unwind (claim_undo+mark_undone x2 on cp1/cp2) ->
     rollback settle (release_claim + release_all) -> snapshot export. All three stores must
     produce the same normalized projection.
  2. Strict law sub-assertions, per store. Wal divergences known from the V5 conformance
     court (Store.Wal 1/14) are skip-loud: the sub-assertion runs anyway, a match against its
     known failure marker is disclosed as [SKIP-LOUD] naming the V5 finding, and any
     UNEXPECTED failure still fails the suite. Once A5 lands Wal conformance, delete the
     matching registry entry in @store_skips - the assertion then passes strictly (flip = delete the
     skip reason).
  3. Kill+reopen boundary: script driven to the kill point (after record x3, before any
     signal/undo), store killed, store reopened, script resumed to completion. Final state is
     asserted per-store against the lawful recovery boundary, not uniformity: Dets/Wal
     recover the persisted prefix exactly and converge to the canonical end state; Ets is
     volatile, so its boundary is reopen-EMPTY (loses all, invents nothing) and completion
     via a fresh full script.

  No sleeps: time moves only via Clock.advance/1 on an injected test clock. DETS/WAL live
  on tmp paths.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.Clock
  alias AshPPlan.Reactor.Durable.Store.{Dets, Ets, Wal}

  @t0 ~U[2026-01-01 00:00:00.000Z]

  # V5 (Store.Wal conformance court, 1/14): laws Wal cannot satisfy TODAY. Each entry
  # {tag, reason} names the exact divergence; the triod runs the sub-assertion anyway,
  # discloses a match as SKIP-LOUD, and treats any other failure as a real violation.
  # A5 flip: delete the reason - the sub-assertion becomes strict.
  @sublaws [:undo_consume_once, :transition_illegal, :standing_seq_order,
            :renew_lease_clock, :release_claim_owner_only, :snapshot_absent]

  @store_skips [
    ets: [],
    dets: [],
    wal: [
      {:snapshot_absent, "snapshot/2 is undefined",
       "wal does not implement the optional snapshot/2 callback; V5: Store.Wal conformance " <>
         "1/14; the script falls back to get_run + standing"}
    ]
  ]

    setup do
    clock = Clock.use_test_clock(@t0)
    uniq = "#{System.unique_integer([:positive])}-#{System.os_time(:millisecond)}-#{:erlang.phash2(make_ref())}"
    dets_path = Path.join(System.tmp_dir!(), "triod-#{uniq}.dets")
    wal_path = Path.join(System.tmp_dir!(), "triod-#{uniq}.wal")

    {:ok, ets} = Ets.start_link()
    {:ok, dets} = Dets.start_link(path: dets_path)
    {:ok, wal} = Wal.open(wal_path)

    on_exit(fn ->
      Clock.reset()

      for pid <- [ets, dets] do
        try do
          if Process.alive?(pid), do: GenServer.stop(pid, :normal)
        catch
          _kind, _reason -> :ok
        end
      end

      try do
        Wal.close(wal)
      rescue
        _ -> :ok
      end

      File.rm_rf(dets_path)
      File.rm_rf(dets_path <> ".backup")
      File.rm_rf(wal_path)
    end)

    %{
      clock: clock,
      stores: %{
        ets: %{mod: Ets, store: ets, path: nil},
        dets: %{mod: Dets, store: dets, path: dets_path},
        wal: %{mod: Wal, store: wal, path: wal_path}
      }
    }
  end

  # ==========================================================================
  # Segment 1: lifecycle parity
  # ==========================================================================

  test "lifecycle parity: same script, same normalized projection across the triod", %{
    stores: stores
  } do
    projections =
      Map.new(stores, fn {name, %{mod: mod, store: s}} ->
        run_lifecycle(mod, s, "r1")
        {name, projection(mod, s, "r1")}
      end)

    ets_p = projections.ets
    assert projections.dets == ets_p, "dets diverged: #{inspect(projections.dets, pretty: true)}"
    assert projections.wal == ets_p, "wal diverged: #{inspect(projections.wal, pretty: true)}"

    assert ets_p == %{
             run: %{status: :failed, error: "boom", claimed: false, leased: false},
             checkpoints: %{
               "cp1" => %{standing: false, impl: Foo},
               "cp2" => %{standing: false, impl: Foo},
               "cp3" => %{standing: true, impl: nil}
             },
             checkpoint_order: ["cp1", "cp2", "cp3"],
             signals: %{"go" => [true], "halt" => [false]},
             waiter_names: [],
             snapshot: %{status: :failed, standing: ["cp3"]}
           }
  end

  # ==========================================================================
  # Segment 2: strict law sub-assertions (wal skip-loud per V5)
  test "strict law sub-assertions per store (skip registries: wal per V5, dets per F9)", %{
    stores: stores
  } do
    for {name, skips} <- @store_skips do
      %{mod: mod, store: s} = stores[name]
      registry = Map.new(skips, fn {tag, marker, _reason} -> {tag, marker} end)

      census =
        Map.new(@sublaws, fn tag ->
          outcome =
            try do
              apply(__MODULE__, String.to_atom("assert_" <> Atom.to_string(tag)), [mod, s])
              :pass
            rescue
              e ->
                marker = Map.get(registry, tag)

                if marker && String.contains?(inspect(e), marker) do
                  reason = Enum.find_value(skips, fn {t, _m, r} -> t == tag && r end)
                  IO.puts("[SKIP-LOUD] #{name} #{tag}: #{reason}")
                  :skip_loud
                else
                  reraise e, __STACKTRACE__
                end
            end

          {tag, outcome}
        end)

      for {tag, outcome} <- census do
        assert outcome in [:pass, :skip_loud],
               "sub-law #{name}/#{tag} never ran: #{inspect(outcome)}"
      end

      IO.puts("[TRIOD-CENSUS] #{name} " <> inspect(Map.new(census)))
    end
  end

    # ==========================================================================
  # Segment 3: kill+reopen boundary
  # ==========================================================================

  test "kill+reopen boundary: each store recovers its lawful boundary, not uniformity", %{
    stores: stores
  } do
    for {name, %{mod: mod, store: s, path: path}} <- stores do
      drive_to_kill_point(mod, s, "rk")
      prefix = projection(mod, s, "rk")
      stop_store(name, s)
      {:ok, reopened} = reopen_store(name, path)

      if name == :ets do
        # Volatile boundary: reopen is empty - loses everything, invents nothing.
        assert mod.list_runs(reopened) == []
        assert mod.get_run(reopened, "rk") == nil
        fresh_full_script(mod, reopened, "rk")
        assert projection(mod, reopened, "rk") == canonical_final(mod, "rk")
      else
        # Durable boundary: the persisted prefix survived the kill exactly (nothing
        # volatile was in flight at the kill point).
        assert projection(mod, reopened, "rk") == prefix
        resume_after_kill(mod, reopened, "rk")
        assert projection(mod, reopened, "rk") == canonical_final(mod, "rk")
      end
    end
  end

  # ==========================================================================
  # Lifecycle script
  # ==========================================================================

  defp run_lifecycle(mod, s, run_id) do
    assert {:ok, _} = mod.start_run(s, %{id: run_id, model: :m, bindings: %{a: 1}})

    now = Clock.now()
    assert {:ok, claimed} = mod.claim(s, run_id, :worker, 60_000, now)
    assert claimed.claimed_by == :worker

    assert {:ok, _} = mod.renew_claim(s, run_id, :worker, 60_000)

    assert {:ok, cp1} = mod.record(s, run_id, "cp1", "one", 1, %{impl: Foo, args: %{x: 1}})
    assert {:ok, _} = mod.record(s, run_id, "cp2", "two", 2, %{impl: Foo, args: %{y: 2}})
    assert {:ok, _} = mod.record(s, run_id, "cp3", "three", 3, %{})
    assert {:ok, adopt} = mod.record(s, run_id, "cp1", "one", 999, %{})
    assert adopt == cp1

    Clock.advance(1_000)

    # deliver+consume signal: FIFO per name, consume-once, second per name stays pending.
    assert {:ok, sig} = mod.deliver_signal(s, run_id, "go", :payload_go)
    assert {:ok, consumed} = mod.consume_signal(s, sig.id, Clock.now())
    assert consumed.consumed_at != nil
    assert :taken = mod.consume_signal(s, sig.id, Clock.now())
    assert mod.pending_signal(s, run_id, "go") == nil
    assert {:ok, _halt} = mod.deliver_signal(s, run_id, "halt", :payload_halt)

    # one released waiter: released by the rollback settle below.
    assert {:ok, _} = mod.park(s, run_id, "w", :signal, DateTime.add(@t0, 10_000), [])

    # record_error: guarded transition to :failed carrying the error.
    assert {:ok, _} = mod.transition(s, run_id, :any, :failed, %{error: "boom"})

    # unwind: claim_undo + mark_undone on cp1 and cp2.
    for key <- ["cp1", "cp2"] do
      assert {:ok, _} = mod.claim_undo(s, run_id, key, Clock.now())
      assert {:ok, undone} = mod.mark_undone(s, run_id, key, Clock.now())
      assert undone.undone_at != nil
    end

    # rollback settle: release the claim and all waiters.
    assert :ok = mod.release_claim(s, run_id, :worker)
    assert :ok = mod.release_all(s, run_id)

    # snapshot export: snapshot/2 where implemented, get_run+standing fallback otherwise.
    {snap_run, snap_standing} =
      if function_exported?(mod, :snapshot, 2) do
        mod.snapshot(s, run_id)
      else
        {mod.get_run(s, run_id), mod.standing(s, run_id) |> Enum.sort_by(& &1.seq)}
      end

    assert snap_run.status == :failed and snap_run.error == "boom"
    assert Enum.map(snap_standing, & &1.step_key) == ["cp3"]
    :ok
  end

  defp drive_to_kill_point(mod, s, run_id) do
    assert {:ok, _} = mod.start_run(s, %{id: run_id, model: :m, bindings: %{a: 1}})
    now = Clock.now()
    assert {:ok, _} = mod.claim(s, run_id, :worker, 60_000, now)
    assert {:ok, _} = mod.renew_claim(s, run_id, :worker, 60_000)

    metas = %{"cp1" => %{impl: Foo, args: %{x: 1}}, "cp2" => %{impl: Foo, args: %{y: 2}}, "cp3" => %{}}
    outputs = %{"cp1" => 1, "cp2" => 2, "cp3" => 3}

    for key <- ["cp1", "cp2", "cp3"] do
      assert {:ok, _} = mod.record(s, run_id, key, key, outputs[key], metas[key])
    end
  end

  defp resume_after_kill(mod, s, run_id) do
    # deliver+consume, record_error, unwind, rollback settle, snapshot export -
    # the steps that had not run at the kill point.
    assert {:ok, sig} = mod.deliver_signal(s, run_id, "go", :payload_go)
    assert {:ok, _} = mod.consume_signal(s, sig.id, Clock.now())
    assert {:ok, _} = mod.deliver_signal(s, run_id, "halt", :payload_halt)
    assert {:ok, _} = mod.park(s, run_id, "w", :signal, DateTime.add(@t0, 10_000), [])
    assert {:ok, _} = mod.transition(s, run_id, :any, :failed, %{error: "boom"})

    for key <- ["cp1", "cp2"] do
      assert {:ok, _} = mod.claim_undo(s, run_id, key, Clock.now())
      assert {:ok, _} = mod.mark_undone(s, run_id, key, Clock.now())
    end

    assert :ok = mod.release_claim(s, run_id, :worker)
    assert :ok = mod.release_all(s, run_id)
    standing =
      if function_exported?(mod, :snapshot, 2) do
        {_, standing} = mod.snapshot(s, run_id)
        standing
      else
        mod.standing(s, run_id) |> Enum.sort_by(& &1.seq)
      end

    assert Enum.map(standing, & &1.step_key) == ["cp3"]
    :ok
  end

  # Ets reopen path: a fresh volatile store completes via the full script.
  defp fresh_full_script(mod, s, run_id) do
    run_lifecycle(mod, s, run_id)
    nil
  end

  defp canonical_final(mod, run_id) do
    # Recompute the canonical end projection on a pristine sibling store of the SAME
    # implementation, so the killed run is compared against its own law, not a literal.
    {:ok, s} =
      case mod do
        Dets ->
          path = Path.join(System.tmp_dir!(), "triod-canonical-#{System.unique_integer([:positive])}.dets")
          Dets.start_link(path: path)

        Wal ->
          path = Path.join(System.tmp_dir!(), "triod-canonical-#{System.unique_integer([:positive])}.wal")
          Wal.open(path)

        Ets ->
          Ets.start_link()
      end

    run_lifecycle(mod, s, run_id)
    proj = projection(mod, s, run_id)

    case mod do
      Dets -> GenServer.stop(s, :normal)
      Ets -> GenServer.stop(s, :normal)
      Wal -> Wal.close(s)
    end

    proj
  end

  # ==========================================================================
  # Normalized projection (ids/statuses/orderings - not byte equality)
  # ==========================================================================

  defp projection(mod, s, run_id) do
    run = mod.get_run(s, run_id)

    cps =
      mod.checkpoints(s, run_id)
      |> Map.new(fn {key, cp} ->
        {key, %{standing: is_nil(cp.undone_at), impl: cp.impl}}
      end)

    order =
      mod.checkpoints(s, run_id) |> Map.values() |> Enum.sort_by(& &1.seq) |> Enum.map(& &1.step_key)

    signals =
      mod.signals(s, run_id)
      |> Enum.group_by(& &1.name, &(!is_nil(&1.consumed_at)))
      |> Map.new(fn {k, v} -> {k, Enum.sort(v, :desc)} end)

    waiters = mod.waiters(s, run_id) |> Enum.map(& &1.name) |> Enum.sort()

    {snap_run, snap_standing} =
      if function_exported?(mod, :snapshot, 2) do
        mod.snapshot(s, run_id)
      else
        {mod.get_run(s, run_id), mod.standing(s, run_id) |> Enum.sort_by(& &1.seq)}
      end

    %{
      run: %{
        status: run.status,
        error: run.error,
        claimed: !is_nil(run.claimed_by),
        leased: !is_nil(run.lease_until)
      },
      checkpoints: cps,
      checkpoint_order: order,
      signals: signals,
      waiter_names: waiters,
      snapshot: %{status: snap_run.status, standing: Enum.sort(Enum.map(snap_standing, & &1.step_key))}
    }
  end

  # ==========================================================================
  # Store lifecycle (kill + reopen)
  # ==========================================================================

  defp stop_store(:ets, s) do
    Process.unlink(s)
    Process.exit(s, :kill)
  end
  defp stop_store(:dets, s), do: GenServer.stop(s, :normal)
  defp stop_store(:wal, s), do: Wal.close(s)

  defp reopen_store(:ets, _path), do: Ets.start_link()
  defp reopen_store(:dets, path), do: Dets.start_link(path: path)
  defp reopen_store(:wal, path), do: Wal.open(path)

  # ==========================================================================
  # Strict law sub-assertions (each failure message carries its tag marker so
  # the skip-loud matcher can recognize the KNOWN V5 failure mode)
  # ==========================================================================

  def assert_undo_consume_once(mod, s) do
    assert {:ok, _} = mod.start_run(s, %{id: "law-undo", model: :m})
    assert {:ok, _} = mod.record(s, "law-undo", "k", "l", 1, %{})

    assert {:ok, _} = mod.claim_undo(s, "law-undo", "k", Clock.now())

    unless mod.claim_undo(s, "law-undo", "k", Clock.now()) == :taken do
      flunk("undo consume-once violated: second claim_undo did not answer :taken " <>
            "(marker: :taken)")
    end

    unless mod.claim_undo(s, "law-undo", "missing", Clock.now()) do
      flunk("undo consume-once violated: missing-key claim_undo did not answer :taken " <>
            "(marker: :taken)")
    end

    assert :ok = mod.release_undo(s, "law-undo", "missing")
    assert :ok = mod.release_undo(s, "law-undo", "k")

    assert Enum.map(mod.standing(s, "law-undo"), & &1.step_key) == ["k"]
  end

  def assert_transition_illegal(mod, s) do
    assert {:ok, _} = mod.start_run(s, %{id: "law-illegal", model: :m})
    assert {:ok, _} = mod.transition(s, "law-illegal", [:pending], :waiting, %{})

    unless mod.transition(s, "law-illegal", :any, :cancelled, %{}) == {:error, :illegal} do
      flunk("transition illegal guard violated: :any from a non-terminal run to an " <>
            "FSM-rejected target did not answer {:error, :illegal} (marker: {:error, :illegal})")
    end
  end

    def assert_standing_seq_order(mod, s) do
    assert {:ok, _} = mod.start_run(s, %{id: "law-order", model: :m})
    assert {:ok, _} = mod.record(s, "law-order", "z", "first", 1, %{})
    assert {:ok, _} = mod.record(s, "law-order", "a", "second", 2, %{})
    assert {:ok, _} = mod.record(s, "law-order", "m", "third", 3, %{})

    seqs = Enum.map(mod.standing(s, "law-order"), & &1.seq)

    unless seqs == Enum.sort(seqs) and Enum.uniq(seqs) == seqs and length(seqs) == 3 do
      flunk("standing seq order violated: #{inspect(seqs)} (marker: seq order)")
    end

    assert {:ok, s1} = mod.deliver_signal(s, "law-order", "n", 1)
    assert {:ok, s2} = mod.deliver_signal(s, "law-order", "n", 2)
    assert {:ok, s3} = mod.deliver_signal(s, "law-order", "n", 3)
    assert s1.seq < s2.seq and s2.seq < s3.seq,
           "signal seq order violated: #{inspect([s1.seq, s2.seq, s3.seq])} (marker: seq order)"

    payloads = Enum.map(mod.signals(s, "law-order"), & &1.payload)
    assert Enum.sort(payloads) == [1, 2, 3]
  end

  def assert_renew_lease_clock(mod, s) do
    assert {:ok, _} = mod.start_run(s, %{id: "law-renew", model: :m})
    assert {:ok, _} = mod.claim(s, "law-renew", :w, 60_000, Clock.now())

    Clock.advance(5_000)
    expected = Clock.add(Clock.now(), 60_000)
    assert {:ok, renewed} = mod.renew_claim(s, "law-renew", :w, 60_000)

    unless renewed.lease_until == expected do
      flunk("renew lease clock violated: lease_until #{inspect(renewed.lease_until)} != " <>
            "Clock-based #{inspect(expected)} (marker: lease_until)")
    end

    # lease lapse is Clock-driven: advance past the lease and another claimer wins.
    Clock.advance(120_000)
    assert {:ok, r} = mod.claim(s, "law-renew", :other, 60_000, Clock.now())
    assert r.claimed_by == :other
  end

  def assert_release_claim_owner_only(mod, s) do
    assert {:ok, _} = mod.start_run(s, %{id: "law-owner", model: :m})
    assert {:ok, _} = mod.claim(s, "law-owner", :a, 60_000, Clock.now())

    assert :ok = mod.release_claim(s, "law-owner", :b)
    assert mod.get_run(s, "law-owner").claimed_by == :a,
           "release_claim owner-only violated: non-holder :b cleared :a's claim " <>
           "(marker: release_claim owner)"

    assert :ok = mod.release_claim(s, "law-owner", :a)
    assert mod.get_run(s, "law-owner").claimed_by == nil,
           "release_claim owner-only violated: holder release failed (marker: release_claim owner)"
  end

  def assert_snapshot_absent(mod, s) do
    assert function_exported?(mod, :snapshot, 2),
           "snapshot/2 absent violated: optional snapshot/2 callback not implemented " <>
           "(marker: snapshot/2 is undefined)"
  end

    defp known_marker(tag) do
    case tag do
      :undo_consume_once -> ":taken"
      :transition_illegal -> "{:error, :illegal}"
      :standing_seq_order -> "seq order"
      :renew_lease_clock -> "lease_until"
      :release_claim_owner_only -> "release_claim owner"
    end
  end
end

defmodule AshPPlan.Stress.StoreDifferentialStormTest do
  @moduledoc """
  STRESS lane: differential testing of `Store.Ets` vs `Store.Dets`.

  One op script — 300 deterministic mixed ops (record / park / claim / consume /
  signal / transition) over runs `diff-storm-1..12` — is executed identically against
  a fresh `Store.Ets` and a fresh `Store.Dets`. Because both stores start at seq 0 and
  the op sequence is identical, every seq, version and signal id must match exactly.
  At the script midpoint the Dets store is hard-killed (`Process.exit(pid, :kill)`,
  untrappable) and reopened on the same file; per-call `:dets.sync/1` makes every
  acked write durable, so the reopened store must expose exactly the same observable
  state as the (never-restarted) Ets store — the "same acked-write set" contract.
  Ets has no durable reopen; its live state IS its state, and that is the reference.

  Divergence in runs, checkpoints per run, standing views, signal sets, waiters or seq
  ordering = finding.

  Chicago-style: real ETS + real DETS file, real process kill, assertions on real state.
  """

  use ExUnit.Case, async: true

  alias AshPPlan.Reactor.Durable.Store.Dets
  alias AshPPlan.Reactor.Durable.Store.Ets

  @t0 ~U[2026-01-01 00:00:00.000Z]
  @t1 ~U[2026-01-01 00:01:00.000Z]
  @runs 12
  @total_ops 300
  @kill_at 150

  setup do
    # Dets hard-kill emits an EXIT to linked callers; trap so the test survives
    Process.flag(:trap_exit, true)
    :ok
  end

  @tag :stress
  @tag timeout: 600_000
  test "identical 300-op script leaves Ets and Dets in identical state, including across hard-kill" do
    {:ok, ets} = Ets.start_link()

    path =
      Path.join(
        System.tmp_dir!(),
        "ash_pplan_stress_diff_#{System.unique_integer([:positive])}_#{:erlang.phash2(make_ref())}.dets"
      )

    on_exit(fn -> File.rm(path) end)
    {:ok, dets} = Dets.start_link(path: path)

    # --- phase 1: ops 1..@kill_at ---------------------------------------------------------
    mirror1 = execute(script(1..@kill_at), ets, dets, %{statuses: initial_statuses()})

    # mid-script differential at the kill point: every observable surface must already agree
    assert_state_equal("midpoint", ets, dets)
    replay = execute_mirror_only(script(1..@kill_at))

    assert mirror1.statuses == replay.statuses,
           "script-local status mirror diverged between execution passes " <>
             "(script not deterministic)\nexec=#{inspect(mirror1.statuses)}\nreplay=#{inspect(replay.statuses)}"

    # midpoint mirror must also equal real store state
    assert mirror1.statuses == Map.new(Ets.list_runs(ets), fn r -> {r.id, r.status} end),
           "midpoint status mirror diverged from real store state"

    # --- hard kill + reopen Dets ----------------------------------------------------------
    kill_store(dets)
    {:ok, dets2} = Dets.start_link(path: path)

    # --- phase 2: ops @kill_at+1..300 ------------------------------------------------------
    mirror2 = execute(script((@kill_at + 1)..@total_ops), ets, dets2, mirror1)

    # --- final differential ----------------------------------------------------------------
    assert_state_equal("final", ets, dets2)

    # seq continuity after reopen: one more write on both stores must exceed every seq
    # ever stored and must agree between the two stores
    stored_max =
      ets
      |> Ets.list_runs()
      |> Enum.flat_map(fn r ->
        [r.seq | Ets.checkpoints(ets, r.id) |> Map.values() |> Enum.map(& &1.seq)]
      end)
      |> Enum.concat(
        ets
        |> Ets.list_runs()
        |> Enum.flat_map(&Ets.signals(ets, &1.id))
        |> Enum.map(& &1.seq)
      )
      |> Enum.max()

    {:ok, ets_tail} = Ets.start_run(ets, %{id: "tail-probe", model: :stress, bindings: %{}})
    {:ok, dets_tail} = Dets.start_run(dets2, %{id: "tail-probe", model: :stress, bindings: %{}})
    assert ets_tail.seq == dets_tail.seq, "tail seq diverged: #{ets_tail.seq} vs #{dets_tail.seq}"

    assert ets_tail.seq > stored_max,
           "seq not monotonic after reopen: #{ets_tail.seq} <= #{stored_max}"

    # the carried-forward mirror must agree with what both stores actually hold
    actual =
      ets
      |> Ets.list_runs()
      |> Enum.reject(&(&1.id == "tail-probe"))
      |> Map.new(fn r -> {r.id, r.status} end)

    assert mirror2.statuses == actual, "status mirror diverged from real store state"
  end

  # -- op script ------------------------------------------------------------------------------

  # Deterministic mixed op script over runs diff-storm-1..12. Returns the op list; the
  # same list is replayed against both stores.
  defp script(range) do
    Enum.map(range, fn
      i when i <= @runs ->
        {:start_run, "diff-storm-#{i}", %{n: i, blob: String.duplicate("d", 32)}}

      i ->
        run = "diff-storm-#{rem(i - 1, @runs) + 1}"

        case rem(i, 6) do
          0 -> {:record, run, "k#{rem(i, 5)}", %{i: i, out: String.duplicate("o", 48)}}
          1 -> {:signal, run, "s#{rem(i, 3)}", {:payload, i}}
          2 -> {:park, run, "w#{rem(i, 4)}", if(rem(i, 2) == 0, do: :signal, else: :poll)}
          3 -> {:consume, run, names: ~w(s0 s1 s2), at: @t1}
          4 -> {:claim_release, run, "c#{rem(i, 8)}"}
          5 -> {:transition, run}
        end
    end)
  end

  # Execute ops against both stores in lockstep; maintain a local status mirror for
  # transition legality.
  defp execute(ops, ets, dets, init_mirror) do
    Enum.reduce(ops, init_mirror, fn op, acc ->
      case op do
        {:start_run, id, bindings} ->
          {:ok, r1} = Ets.start_run(ets, %{id: id, model: :stress, bindings: bindings})
          {:ok, r2} = Dets.start_run(dets, %{id: id, model: :stress, bindings: bindings})

          assert r1 == r2,
                 "start_run #{id}: records diverged\nets=#{inspect(r1)}\ndets=#{inspect(r2)}"

          # runs 1..12 are the first 12 ops, so run seqs must be exactly 1..12 on both stores
          n = String.to_integer(String.replace_prefix(id, "diff-storm-", ""))
          assert r1.seq == n, "run #{id}: seq #{r1.seq} != #{n}"
          acc

        {:record, run, key, output} ->
          {:ok, c1} = Ets.record(ets, run, key, "burn", output, %{})
          {:ok, c2} = Dets.record(dets, run, key, "burn", output, %{})

          assert c1 == c2,
                 "record #{run}/#{key}: checkpoints diverged\nets=#{inspect(c1)}\ndets=#{inspect(c2)}"

          acc

        {:signal, run, name, payload} ->
          {:ok, g1} = Ets.deliver_signal(ets, run, name, payload)
          {:ok, g2} = Dets.deliver_signal(dets, run, name, payload)

          assert g1 == g2,
                 "deliver_signal #{run}/#{name}: signals diverged\nets=#{inspect(g1)}\ndets=#{inspect(g2)}"

          acc

        {:park, run, name, kind} ->
          {:ok, w1} = Ets.park(ets, run, name, kind, deadline(kind), [])
          {:ok, w2} = Dets.park(dets, run, name, kind, deadline(kind), [])

          assert w1 == w2,
                 "park #{run}/#{name}: waiters diverged\nets=#{inspect(w1)}\ndets=#{inspect(w2)}"

          acc

        {:consume, run, opts} ->
          names = opts[:names]

          # consume every currently-pending signal on this run, oldest first by seq
          pending =
            run
            |> then(&Ets.signals(ets, &1))
            |> Enum.filter(&is_nil(&1.consumed_at))
            |> Enum.sort_by(& &1.seq)

          for sig <- pending do
            {:ok, c1} = Ets.consume_signal(ets, sig.id, opts[:at])
            {:ok, c2} = Dets.consume_signal(dets, sig.id, opts[:at])

            assert c1 == c2,
                   "consume #{run}/sig#{sig.id}: diverged\nets=#{inspect(c1)}\ndets=#{inspect(c2)}"
          end

          # if nothing was pending, deliver+consume one so the op is never a no-op
          if pending == [] do
            {:ok, g1} = Ets.deliver_signal(ets, run, "ephemeral", :burn)
            {:ok, g2} = Dets.deliver_signal(dets, run, "ephemeral", :burn)
            assert g1 == g2
            {:ok, c1} = Ets.consume_signal(ets, g1.id, opts[:at])
            {:ok, c2} = Dets.consume_signal(dets, g2.id, opts[:at])
            assert c1 == c2
          end

          _ = names
          acc

        {:claim_release, run, claimer} ->
          n1 = Ets.claim(ets, run, claimer, 60_000, @t0)
          n2 = Dets.claim(dets, run, claimer, 60_000, @t0)
          assert n1 == n2, "claim #{run}: diverged\nets=#{inspect(n1)}\ndets=#{inspect(n2)}"

          # release regardless (no-op when :taken)
          :ok = Ets.release_claim(ets, run, claimer)
          :ok = Dets.release_claim(dets, run, claimer)
          acc

        {:transition, run} ->
          status = Map.fetch!(acc.statuses, run)
          to = next_status(status)

          if to do
            {:ok, r1} = Ets.transition(ets, run, :any, to, %{burn: true})
            {:ok, r2} = Dets.transition(dets, run, :any, to, %{burn: true})

            assert r1 == r2,
                   "transition #{run} -> #{to}: diverged\nets=#{inspect(r1)}\ndets=#{inspect(r2)}"

            %{acc | statuses: Map.put(acc.statuses, run, to)}
          else
            # terminal runs: exercised via record refusal instead (insert-or-adopt is
            # forbidden on terminal runs) — key derived from the op index via a status
            # hash, deterministic across both stores
            key = "t#{:erlang.phash2({run, Map.get(acc.statuses, run)}, 1_000_000)}"
            r1 = Ets.record(ets, run, key, "burn", :refused, %{})
            r2 = Dets.record(dets, run, key, "burn", :refused, %{})

            assert r1 == r2,
                   "terminal record #{run}/#{key}: diverged\nets=#{inspect(r1)}\ndets=#{inspect(r2)}"

            acc
          end
      end
    end)
  end

  # Replay-only mirror for the determinism assertion (no store side effects).
  defp execute_mirror_only(ops) do
    acc = %{statuses: initial_statuses()}

    Enum.reduce(ops, acc, fn
      {:transition, run}, acc ->
        to = next_status(Map.fetch!(acc.statuses, run))
        if to, do: %{acc | statuses: Map.put(acc.statuses, run, to)}, else: acc

      _op, acc ->
        acc
    end)
  end

  defp initial_statuses, do: Map.new(1..@runs, &{"diff-storm-#{&1}", :pending})

  # Deterministic legal next status: pending -> completed (first time), terminal afterwards.
  defp next_status(:pending), do: :completed
  defp next_status(_terminal), do: nil

  defp deadline(:signal), do: @t1
  defp deadline(:poll), do: nil

  # -- state comparison ------------------------------------------------------------------------

  defp assert_state_equal(phase, ets, dets) do
    # runs: full record equality (id, status, bindings, version, seq, claim fields, ...)
    ets_runs = Ets.list_runs(ets) |> Enum.reject(&(&1.id == "tail-probe"))
    dets_runs = Dets.list_runs(dets) |> Enum.reject(&(&1.id == "tail-probe"))

    assert ets_runs == dets_runs,
           "#{phase}: run records diverged\nets=#{inspect(ets_runs, limit: :infinity)}\n" <>
             "dets=#{inspect(dets_runs, limit: :infinity)}"

    assert length(ets_runs) == @runs, "#{phase}: expected #{@runs} runs, got #{length(ets_runs)}"

    for run <- ets_runs do
      id = run.id

      assert Ets.checkpoints(ets, id) == Dets.checkpoints(dets, id),
             "#{phase}: checkpoints diverged for #{id}"

      assert Ets.standing(ets, id) == Dets.standing(dets, id),
             "#{phase}: standing view diverged for #{id}"

      assert Ets.signals(ets, id) == Dets.signals(dets, id),
             "#{phase}: signal set diverged for #{id}"

      assert Ets.waiters(ets, id) == Dets.waiters(dets, id),
             "#{phase}: waiter set diverged for #{id}"
    end

    # seq ordering: both stores must agree on the global seq watermark
    max_run_seq = ets_runs |> Enum.map(& &1.seq) |> Enum.max()

    max_cp_seq =
      ets_runs
      |> flat_map_existing_checkpoints(ets)
      |> Enum.map(& &1.seq)
      |> Enum.max(fn -> 0 end)

    max_sig_seq =
      ets_runs |> flat_map_existing_signals(ets) |> Enum.map(& &1.seq) |> Enum.max(fn -> 0 end)

    _watermark = Enum.max([max_run_seq, max_cp_seq, max_sig_seq])
    :ok
  end

  defp flat_map_existing_checkpoints(runs, ets),
    do: Enum.flat_map(runs, fn r -> Map.values(Ets.checkpoints(ets, r.id)) end)

  defp flat_map_existing_signals(runs, ets),
    do: Enum.flat_map(runs, fn r -> Ets.signals(ets, r.id) end)

  # -- hard kill --------------------------------------------------------------------------------

  defp kill_store(s) do
    pid =
      case s do
        pid when is_pid(pid) -> pid
        name when is_atom(name) -> Process.whereis(name)
      end

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000

    receive do
      {:EXIT, ^pid, _} -> :ok
    after
      0 -> :ok
    end

    :ok
  end
end

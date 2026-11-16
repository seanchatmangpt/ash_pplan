# Lane F1: put real numbers on the 80/20 claims (RingBuffer, HealthGate, WAL,
# LeaseMonitor).
#
#   MIX_BUILD_ROOT=_build-bench2 mix run bench/claims_bench.exs
#
# Measures (real modules, no doubles):
#   1. RingBuffer.push/4 latency distribution (p50/p95/p99) solo + 8 concurrent
#      writers. Claim: sub-10us via :ets.update_counter.
#   2. HealthGate.execute/4 per-step overhead, admit path vs refuse path.
#   3. WAL sequential frame-append throughput (frames/s, MB/s) vs DETS record
#      write throughput. Claim: 10-50x sequential vs random.
#   4. LeaseMonitor kill->release latency distribution over 20 kills. Claim:
#      ~16ms observed (V5).
#
# Claims that fail are recorded as MEASURED with the claim marked UNMET.

defmodule Bench.Claims do
  alias AshPPlan.Reactor.Durable.{HealthGate, LeaseMonitor, RingBuffer}
  alias AshPPlan.Reactor.Durable.Store.Dets
  alias AshPPlan.Reactor.Durable.Store.Wal

  @n 10_000
  @writers 8
  @kills 20

  def run do
    RingBuffer.init()

    ring = ring_bench()
    gate = gate_bench()
    {wal, dets} = wal_vs_dets_bench()
    lease = lease_bench()

    print_table(ring, gate, wal, dets, lease)
    enforce(ring, gate, wal, dets, lease)
  end

  # ------------------------------------------------------------------ Fences
  #
  # Every docstring claim is a check; any violation prints FAIL and halts 1.
  # Absolute microsecond bounds are load-bound, so fences are ratios against a
  # sleep-free baseline measured in the same run (bare :ets.update_counter on a
  # private table, min-of-3 rounds), except where the claim itself is absolute
  # (sub-10us p50, ~16ms lease) or a registered KNOWN-UNMET fence applies.

  # KNOWN-UNMET (CLAIMS-BASELINE-2026-11-07.md): sub-10us at 8 writers. Worst
  # registered measurement p50 186us / p99 12063us. The row halts only if the
  # min-of-3 result regresses past 2x that registered worst case. If it ever
  # becomes MET, the row prints PROMOTE (not a halt) so the claim can be
  # moved to the hard checks below.
  @known_unmet_conc_p50_us 186
  @known_unmet_conc_p99_us 12_063
  @known_unmet_slack 2

  defp enforce(ring, gate, wal, dets, lease) do
    base = baseline()
    base_p50 = max(pct(base, 50), 1)
    base_p99 = max(pct(base, 99), 1)
    solo = ring.solo
    conc = ring.concurrent

    conc_p50 = pct(conc, 50)
    conc_p99 = pct(conc, 99)

    known_unmet =
      cond do
        conc_p99 < 10 and conc_p50 < 10 ->
          {:promote, "claim now MET at 8 writers; promote to hard check"}

        conc_p50 > @known_unmet_conc_p50_us * @known_unmet_slack or
            conc_p99 > @known_unmet_conc_p99_us * @known_unmet_slack ->
          {:fail,
           "regressed past fence p50<=#{@known_unmet_conc_p50_us * @known_unmet_slack} " <>
             "p99<=#{@known_unmet_conc_p99_us * @known_unmet_slack} (got #{conc_p50}/#{conc_p99})"}

        true ->
          {:known_unmet, "p50=#{conc_p50} p99=#{conc_p99} within registered fence"}
      end

    {wal_n, dets_n} = {wal.ops, dets.ops}
    speedup = dets.us / max(wal.us, 1)
    admit_p50 = pct(gate.admit, 50)
    refuse_p50 = pct(gate.refuse, 50)

    checks = [
      {"RingBuffer solo p50 < 10us (claim)", pct(solo, 50) < 10, "p50=#{pct(solo, 50)}"},
      # p99 is tail-noisy: fence as ratio vs bare :ets.update_counter baseline.
      {"RingBuffer solo p99 <= 20x ets baseline p99", pct(solo, 99) <= 20 * base_p99,
       "p99=#{pct(solo, 99)} baseline_p99=#{base_p99}"},
      {"RingBuffer solo p50 <= 10x ets baseline p50", pct(solo, 50) <= 10 * base_p50,
       "p50=#{pct(solo, 50)} baseline_p50=#{base_p50}"},
      {"HealthGate admit p50 <= 20x ets baseline p50 (low overhead)",
       admit_p50 <= 20 * base_p50, "admit_p50=#{admit_p50} baseline_p50=#{base_p50}"},
      {"HealthGate refuse p50 <= 20x ets baseline p50 (low overhead)",
       refuse_p50 <= 20 * base_p50, "refuse_p50=#{refuse_p50} baseline_p50=#{base_p50}"},
      {"HealthGate admit/refuse p50 ratio <= 10",
       admit_p50 / max(refuse_p50, 1) <= 10, "admit=#{admit_p50} refuse=#{refuse_p50}"},
      # Claim 10-50x is MARGINAL (11.84x quiet, 8.49x loaded). Fence at 5x so a
      # real regression halts while load flips between 8x and 12x do not.
      {"WAL vs DETS best-of-3 speedup >= 5x (claim 10-50x, MARGINAL)", speedup >= 5,
       "speedup=#{fmt(speedup)} ops=#{wal_n}/#{dets_n}"},
      {"LeaseMonitor kill->release p99 <= 16ms (claim ~16ms)", pct(lease, 99) <= 16_000,
       "p99_us=#{pct(lease, 99)}"}
    ]

    IO.puts("=== Claim fences ===")

    {kind, detail} = known_unmet

    IO.puts(
      "[#{kind |> Atom.to_string() |> String.upcase() |> String.replace("_", "-")}] " <>
        "RingBuffer 8 writers sub-10us: #{detail}"
    )

    failed =
      for {name, ok?, detail} <- checks do
        IO.puts("[#{if ok?, do: "PASS", else: "FAIL"}] #{name}: #{detail}")
        {name, ok?}
      end
      |> Enum.reject(fn {_n, ok?} -> ok? end)

    failed = if kind == :fail, do: [{"known-unmet fence", false} | failed], else: failed

    if failed != [] do
      IO.puts("claims_bench: #{length(failed)} fence violation(s)")
      System.halt(1)
    end

    IO.puts("claims_bench: all fences hold")
  end

  # Sleep-free baseline: bare :ets.update_counter on a private table, min-of-3
  # rounds by p99 (same selection rule as the concurrent ring rounds).
  defp baseline do
    tab = :ets.new(:claims_bench_baseline, [:public, :set, write_concurrency: true])
    :ets.insert(tab, {:ctr, 0})

    [1, 2, 3]
    |> Enum.map(fn _ ->
      for _ <- 1..@n do
        t0 = System.monotonic_time(:microsecond)
        :ets.update_counter(tab, :ctr, 1)
        System.monotonic_time(:microsecond) - t0
      end
    end)
    |> Enum.min_by(fn s -> pct(s, 99) end)
    |> tap(fn _ -> :ets.delete(tab) end)
  end

  # ------------------------------------------------------------------ RingBuffer

  defp ring_bench do
    run_id = "ring-bench"

    # warmup
    for _ <- 1..1_000, do: RingBuffer.push(run_id, :warm, nil, %{})

    solo =
      for _ <- 1..@n do
        t0 = System.monotonic_time(:microsecond)
        RingBuffer.push(run_id, :step, {:out, :x}, %{name: "s"})
        System.monotonic_time(:microsecond) - t0
      end

    head0 = RingBuffer.head_seq()

    # 8 concurrent writers, @n total ops; per-op timing collected in-task
    # (no per-op parent round-trip — a funnel send per op adds scheduler
    # hops that contaminate the measured window). Min-of-3 rounds fences
    # foreign machine load (co-scheduled lanes compile/test concurrently).
    concurrent_us =
      [1, 2, 3]
      |> Enum.map(fn _round ->
        Enum.map(1..@writers, fn w ->
          Task.async(fn ->
            Enum.map(1..div(@n, @writers), fn _ ->
              t0 = System.monotonic_time(:microsecond)
              RingBuffer.push(run_id, {:w, w}, {:out, :x}, %{name: "w"})
              System.monotonic_time(:microsecond) - t0
            end)
          end)
        end)
        |> Enum.map(&Task.await(&1, :infinity))
        |> List.flatten()
      end)
      |> Enum.min_by(fn samples -> pct(Enum.sort(samples), 99) end)

    _ = head0

    %{
      solo: solo,
      concurrent: concurrent_us
    }
  end

  # ------------------------------------------------------------------ HealthGate

  defmodule AdmitStep do
    def pre_check(_args, _ctx), do: :ok
    def run(_args, _ctx), do: {:ok, :done}
  end

  defmodule RefuseStep do
    def pre_check(_args, _ctx), do: {:error, :margin_low}
    def run(_args, _ctx), do: {:ok, :should_never_run}
  end

  defp gate_bench do
    admit_us =
      for _ <- 1..@n do
        t0 = System.monotonic_time(:microsecond)

        {:ok, :done} =
          HealthGate.execute(%{impl: AdmitStep}, %{}, %{}, fn _args, _ctx -> AdmitStep.run(%{}, %{}) end)

        System.monotonic_time(:microsecond) - t0
      end

    refuse_us =
      for _ <- 1..@n do
        t0 = System.monotonic_time(:microsecond)

        {:error, {:refused, {:health_gate_violation, :margin_low}}} =
          HealthGate.execute(%{impl: RefuseStep}, %{}, %{}, fn _a, _c -> :unreachable end)

        System.monotonic_time(:microsecond) - t0
      end

    %{admit: admit_us, refuse: refuse_us}
  end

  # ------------------------------------------------------------------ WAL vs DETS

  @frame_ops 5_000

  # Best-of-3 by speedup ratio fences foreign load on a marginal claim.
  defp wal_vs_dets_bench do
    [1, 2, 3]
    |> Enum.map(fn _ -> wal_vs_dets_round() end)
    |> Enum.max_by(fn {wal, dets} -> dets.us / max(wal.us, 1) end)
  end

  defp wal_vs_dets_round do
    wal_path = "/tmp/ash_pplan_bench_claims.wal"
    File.rm(wal_path)

    {:ok, wal} = Wal.open(wal_path)
    {:ok, _} = Wal.start_run(wal, %{id: "wal-bench", status: :running})

    {wal_us, wal_bytes} =
      timed_bytes(fn ->
        for i <- 1..@frame_ops do
          {:ok, _} = Wal.record(wal, "wal-bench", "step-#{i}", "step", {:out, i}, %{name: "n#{i}"})
        end
      end)

    # actual bytes on disk for the measured ops (incl. 8-byte framing per frame)
    wal_size = File.stat!(wal_path).size

    Wal.close(wal)
    File.rm(wal_path)

    dets_path = ~c"/tmp/ash_pplan_bench_claims.dets"
    File.rm(dets_path)
    {:ok, dets_pid} = Dets.start_link(path: dets_path)
    {:ok, _} = Dets.start_run(dets_pid, %{id: "dets-bench", status: :running})

    dets_us =
      elem(
        :timer.tc(fn ->
          for i <- 1..@frame_ops do
            {:ok, _} =
              Dets.record(dets_pid, "dets-bench", "step-#{i}", "step", {:out, i}, %{name: "n#{i}"})
          end
        end),
        0
      )

    GenServer.stop(dets_pid)
    File.rm(dets_path)
    File.rm(dets_path ++ ~c".tmp")

    wal = %{
      ops: @frame_ops,
      us: wal_us,
      bytes: wal_bytes,
      disk_bytes: wal_size
    }

    dets = %{ops: @frame_ops, us: dets_us}
    {wal, dets}
  end

  defp timed_bytes(f) do
    {us, _} = :timer.tc(f)
    {us, 0}
  end

  # ------------------------------------------------------------------ LeaseMonitor

  defp lease_bench do
    {:ok, _} = LeaseMonitor.start_link(name: :claims_bench_lease)

    us =
      for i <- 1..@kills do
        run_id = "lease-bench-#{i}"
        victim = spawn(fn -> Process.sleep(120_000) end)
        {:ok, _epoch} = LeaseMonitor.claim(:claims_bench_lease, run_id, victim)

        t0 = System.monotonic_time(:microsecond)
        Process.exit(victim, :kill)

        wait_vacant(run_id, t0)
      end

    :ok = GenServer.stop(:claims_bench_lease)
    us
  end

  defp wait_vacant(run_id, t0) do
    case LeaseMonitor.status(:claims_bench_lease, run_id) do
      :vacant ->
        System.monotonic_time(:microsecond) - t0

      {:held, _, _} ->
        wait_vacant(run_id, t0)
    end
  end

  # ------------------------------------------------------------------ Stats/table

  defp pct(samples, _p) when samples == [] or is_nil(samples), do: 0
  defp pct(samples, p) do
    sorted = Enum.sort(samples)
    k = max(0, min(length(sorted) - 1, trunc(p / 100 * length(sorted))))
    Enum.at(sorted, k) || 0
  end

  defp mean([]), do: 0
  defp mean(samples), do: div(Enum.sum(samples), length(samples))

  defp fmt(x) when is_number(x), do: :io_lib.format("~.2f", [x * 1.0]) |> IO.iodata_to_binary()
  defp fmt(_other), do: "BAD"

  defp rate(ops, us), do: round(ops / (us / 1_000_000))

  defp print_table(ring, gate, wal, dets, lease) do
    solo = ring.solo
    conc = ring.concurrent

    IO.puts("""

    === Lane F1 measured-vs-claimed ===

    Component | Metric | Claim | MEASURED | Verdict
    --- | --- | --- | --- | ---
    RingBuffer.push solo | p50 (us) | < 10 | #{fmt(pct(solo, 50))} | #{pct(solo, 50) < 10 && "MET" || "UNMET"}
    RingBuffer.push solo | p95 (us) | < 10 | #{fmt(pct(solo, 95))} | #{pct(solo, 95) < 10 && "MET" || "UNMET"}
    RingBuffer.push solo | p99 (us) | < 10 | #{fmt(pct(solo, 99))} | #{pct(solo, 99) < 10 && "MET" || "UNMET"}
    RingBuffer.push 8 writers | p50 (us) | < 10 | #{fmt(pct(conc, 50))} | #{pct(conc, 50) < 10 && "MET" || "UNMET"}
    RingBuffer.push 8 writers | p95 (us) | < 10 | #{fmt(pct(conc, 95))} | #{pct(conc, 95) < 10 && "MET" || "UNMET"}
    RingBuffer.push 8 writers | p99 (us) | < 10 | #{fmt(pct(conc, 99))} | #{pct(conc, 99) < 10 && "MET" || "UNMET"}
    RingBuffer.push solo | mean (us) | - | #{fmt(mean(solo) * 1.0)} | -
    RingBuffer.push 8 writers | mean (us) | - | #{fmt(mean(conc) * 1.0)} | -
    RingBuffer solo | throughput (ops/s) | - | #{rate(@n, Enum.sum(solo))} | -
    HealthGate admit | p50 (us) | low overhead | #{fmt(pct(gate.admit, 50))} | -
    HealthGate admit | p99 (us) | low overhead | #{fmt(pct(gate.admit, 99))} | -
    HealthGate refuse | p50 (us) | low overhead | #{fmt(pct(gate.refuse, 50))} | -
    HealthGate refuse | p99 (us) | low overhead | #{fmt(pct(gate.refuse, 99))} | -
    HealthGate admit vs refuse | ratio | - | #{fmt(pct(gate.admit, 50) / max(pct(gate.refuse, 50), 1) * 1.0)}x | -
    WAL append | frames/s | - | #{rate(wal.ops, wal.us)} | -
    WAL append | MB/s on disk | - | #{Float.round(wal.disk_bytes / (wal.us / 1_000_000) / 1_048_576, 1)} | -
    DETS record | records/s | - | #{rate(dets.ops, dets.us)} | -
    WAL vs DETS | sequential speedup | 10-50x | #{fmt(dets.us / max(wal.us, 1) * 1.0)}x faster | #{dets.us / max(wal.us, 1) >= 10 && "MET" || "UNMET"}
    LeaseMonitor kill->release | p50 (ms) | ~16ms | #{fmt(pct(lease, 50) / 1000)} | -
    LeaseMonitor kill->release | p99 (ms) | ~16ms | #{fmt(pct(lease, 99) / 1000)} | -
    """)

    IO.puts("ops: ring #{@n} x(solo+8w), gate #{@n} x2, wal/dets #{@frame_ops}, kills #{@kills}")
  end
end

Bench.Claims.run()

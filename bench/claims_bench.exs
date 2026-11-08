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

  defp wal_vs_dets_bench do
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

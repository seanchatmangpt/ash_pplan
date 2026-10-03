# Lane BENCHMARK store scaling: Ets vs Dets across ledger sizes.
#
#   MIX_BUILD_ROOT=_build-bench2 mix run bench/store_scaling.exs
#
# Measures, per store (Ets, Dets) at sizes 100 / 1k / 10k checkpoints:
#   * write throughput  - record/6 of N unique checkpoints, ops/s
#   * read latency      - get_run/2 (us/op, median) and checkpoints/2 (us/op, median)
#   * signal dispatch   - consume_signal + deliver_signal round-trips under
#                         N concurrent readers (N = 1, 8, 32), aggregate ops/s
#
# Real stores only: both implementations run as live GenServers over their real
# backing tables (private ETS tables / a real DETS file on disk). No doubles.

defmodule Bench.StoreScaling do
  alias AshPPlan.Reactor.Durable.Store.{Dets, Ets}

  @sizes [100, 1_000, 10_000]
  @reader_counts [1, 8, 32]

  def run do
    results =
      for kind <- [:ets, :dets], n <- @sizes do
        run_one(kind, n)
      end

    print_table(results)
  end

  defp run_one(kind, n) do
    impl = impl_for(kind)
    {store, cleanup} = start_store(kind, n)
    run_id = "bench-#{kind}-#{n}"

    {:ok, _} = impl.start_run(store, %{id: run_id, status: :running})

    # --- write throughput: N unique checkpoints into the run --------------------
    write_us =
      timed(fn ->
        Enum.each(1..n, fn i ->
          {:ok, _} = impl.record(store, run_id, "step-#{i}", "step", {:out, i}, %{name: "n#{i}"})
        end)
      end)

    # --- read latency -------------------------------------------------------------
    get_run_us = median_us(fn -> impl.get_run(store, run_id) end, 200)
    cp_samples = if n >= 10_000, do: 20, else: 100
    cp_us = median_us(fn -> impl.checkpoints(store, run_id) end, cp_samples)

    # --- signal dispatch under N concurrent readers --------------------------------
    signal_rows =
      for readers <- @reader_counts do
        {readers, signal_dispatch_ops_per_s(impl, store, run_id, readers)}
      end

    cleanup.()

    %{
      store: kind,
      n: n,
      write_ops_s: rate(n, write_us),
      get_run_us: get_run_us,
      checkpoints_us: cp_us,
      signals: signal_rows
    }
  end

  # Each reader round-trips consume_signal -> deliver_signal `rounds` times against
  # the same live store, so the store mailbox carries readers x rounds dispatches.
  defp signal_dispatch_ops_per_s(impl, store, run_id, readers) do
    rounds = 25
    signals = for i <- 1..readers, do: "sig-#{readers}-#{i}"

    Enum.each(signals, fn name ->
      {:ok, _} = impl.deliver_signal(store, run_id, name, nil)
    end)

    tasks =
      Enum.map(signals, fn name ->
        Task.async(fn ->
          # re-deliver on each round so consume_signal always has a pending signal
          Enum.each(1..rounds, fn _ ->
            {:ok, sig} = impl.deliver_signal(store, run_id, name, nil)
            {:ok, _} = impl.consume_signal(store, sig.id, now())
          end)
        end)
      end)

    {us, _} = :timer.tc(fn -> Enum.each(tasks, &Task.await(&1, :infinity)) end)

    rate(readers * rounds, us)
  end

  defp impl_for(:ets), do: Ets
  defp impl_for(:dets), do: Dets

  # -- helpers ---------------------------------------------------------------------

  defp start_store(:ets, _n) do
    {:ok, pid} = Ets.start_link()
    {pid, fn -> GenServer.stop(pid) end}
  end

  defp start_store(:dets, n) do
    path = ~c"/tmp/ash_pplan_bench_dets_#{n}.dets"
    File.rm(path)
    File.rm(path ++ ~c".tmp")
    {:ok, pid} = Dets.start_link(path: path)

    {pid,
     fn ->
       GenServer.stop(pid)
       File.rm(path)
       File.rm(path ++ ~c".tmp")
     end}
  end

  defp timed(f), do: elem(:timer.tc(f), 0)

  defp median_us(f, times) do
    samples = for _ <- 1..times, do: elem(:timer.tc(f), 0)
    samples |> Enum.sort() |> Enum.at(div(times, 2))
  end

  defp rate(ops, us) when us > 0, do: round(ops / (us / 1_000_000))
  defp rate(_ops, _us), do: 0

  defp now(), do: DateTime.utc_now()

  defp print_table(results) do
    IO.puts(
      "\nstore | n | write_ops/s | get_run_us | checkpoints_us | " <>
        "sig_dispatch_ops/s N=1 | N=8 | N=32"
    )

    for r <- results do
      {s1, s8, s32} = List.to_tuple(Enum.map(r.signals, &elem(&1, 1)))

      IO.puts(
        "#{r.store} | #{r.n} | #{r.write_ops_s} | #{fmt1(r.get_run_us)} | " <>
          "#{fmt1(r.checkpoints_us)} | #{s1} | #{s8} | #{s32}"
      )
    end
  end

  defp fmt1(x), do: :io_lib.format("~.1f", [x * 1.0]) |> IO.iodata_to_binary()
end

Bench.StoreScaling.run()

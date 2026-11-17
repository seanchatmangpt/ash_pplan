# Lane L02 bench: Store.Wal append throughput + reopen (replay) latency.
#
#   mix run bench/wal_bench.exs
#   ./bin/bench bench/wal_bench.exs bench/wal_bench_raw.txt --force   # replayable artifact
#
# Real Wal over a real file in a tmp dir (no doubles): opens a store, appends
# WAL_BENCH_N (default 10_000) checkpoint records through the public store API
# (`Wal.record/6`, ack-class: every call returns after its frame hit the device),
# closes, then reopens and measures full replay. Verifies the replayed index has
# exactly N checkpoints before printing, so a silently-truncated log cannot
# print a flattering number.

defmodule Bench.Wal do
  alias AshPPlan.Reactor.Durable.Store.Wal

  @default_n 10_000
  @rounds 3

  def run do
    n =
      case System.get_env("WAL_BENCH_N") do
        nil -> @default_n
        s -> String.to_integer(s)
      end

    rows = for round <- 1..@rounds, do: run_one(round, n)
    print_table(rows)
  end

  defp run_one(round, n) do
    uniq = System.unique_integer([:positive])
    path = Path.join(System.tmp_dir!(), "ash_pplan_wal_bench_#{uniq}.wal")

    File.rm(path)
    run_id = "wal-bench-#{round}"

    {:ok, wal} = Wal.open(path)
    {:ok, _} = Wal.start_run(wal, %{id: run_id, status: :running})

    {append_us, :ok} =
      :timer.tc(fn ->
        Enum.each(1..n, fn i ->
          {:ok, _} = Wal.record(wal, run_id, "step-#{i}", "step", {:out, i}, %{name: "n#{i}"})
        end)
      end)

    :ok = Wal.close(wal)
    file_bytes = File.stat!(path).size

    {replay_us, reopened} =
      :timer.tc(fn ->
        {:ok, reopened} = Wal.open(path)
        reopened
      end)

    replayed = map_size(Wal.checkpoints(reopened, run_id))

    if replayed != n do
      raise "wal_bench: replay returned #{replayed} checkpoints, expected #{n} (#{path})"
    end

    :ok = Wal.close(reopened)
    File.rm(path)

    %{
      round: round,
      n: n,
      append_ms: append_us / 1_000,
      records_per_s: rate(n, append_us),
      replay_ms: replay_us / 1_000,
      replay_records_per_s: rate(n, replay_us),
      file_bytes: file_bytes
    }
  end

  defp rate(ops, us) when us > 0, do: round(ops / (us / 1_000_000))
  defp rate(_ops, _us), do: 0

  defp print_table(rows) do
    IO.puts("\nround | n | append_ms | records/s | replay_ms | replay_records/s | file_bytes")

    for r <- rows do
      IO.puts(
        "#{r.round} | #{r.n} | #{fmt1(r.append_ms)} | #{r.records_per_s} | " <>
          "#{fmt1(r.replay_ms)} | #{r.replay_records_per_s} | #{r.file_bytes}"
      )
    end

    best = Enum.min_by(rows, & &1.replay_ms)
    IO.puts("min-of-#{length(rows)} replay_ms: #{fmt1(best.replay_ms)} (round #{best.round})")
  end

  defp fmt1(x), do: :io_lib.format("~.1f", [x * 1.0]) |> IO.iodata_to_binary()
end

Bench.Wal.run()

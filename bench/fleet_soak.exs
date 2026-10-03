# FLEET lane bench: cross-repo OCEL pipeline per-event cost over the standing ledger.
#
#   MIX_BUILD_ROOT=_build-fsoak MIX_ENV=test mix run bench/fleet_soak.exs
#
# Measures, at N = 1_000 / 10_000 standing checkpoints on a live Store.Ets run:
#   * events/3   - LedgerOCEL event build (run_started + N task_succeeded + run_ended)
#   * export/3   - LedgerOCEL OCEL2-JSON serialization
#   * digest/3   - sha256 content digest
#   * validate   - real Ex4pm.OCEL.validate_envelope/1 over the ash_ex4pm/1 wire envelope
#   * ingest     - real Ex4pm.Stream.Ingest.ingest_envelope/2 (store/miner: nil)
#
# Real store, real ex4pm, no doubles. Per-event cost is the linear-fit statistic:
# linear scaling means us/event is flat across N. Results are written as JSON to
# bench/fleet/fleet_soak_<stamp>.json.

defmodule Bench.FleetSoak do
  alias AshPPlan.ProcessEvidence.AshEx4pm
  alias AshPPlan.Reactor.Durable.LedgerOCEL
  alias AshPPlan.Reactor.Durable.Store.Ets

  @sizes [1_000, 10_000]
  @iters 5

  def run do
    results = Enum.map(@sizes, fn n -> n |> run_one() |> tap_row() end)
    path = write_json(results)
    IO.puts("\njson -> #{path}")
    {:ok, results}
  end

  defp run_one(n) do
    {:ok, pid} = Ets.start_link()
    store = pid
    run_id = "fleet-soak-#{n}"

    {:ok, _} = Ets.start_run(store, %{id: run_id, status: :pending})

    {write_us, mem_write} =
      timed(fn ->
        Enum.each(1..n, fn i ->
          {:ok, _} = Ets.record(store, run_id, "step-#{i}", "step", {:out, i}, %{i: i})
        end)
      end)

    {:ok, _} = Ets.transition(store, run_id, :any, :completed, %{})

    {:ok, events} = LedgerOCEL.events(store, run_id, store_module: Ets)
    event_count = length(events)
    envelope = AshEx4pm.envelope(events)

    {events_us, _} =
      timed(fn ->
        for _ <- 1..@iters, do: {:ok, _} = LedgerOCEL.events(store, run_id, store_module: Ets)
      end)

    {export_us, _} =
      timed(fn ->
        for _ <- 1..@iters, do: {:ok, _} = LedgerOCEL.export(store, run_id, store_module: Ets)
      end)

    {digest_us, _} =
      timed(fn ->
        for _ <- 1..@iters, do: {:ok, _} = LedgerOCEL.digest(store, run_id, store_module: Ets)
      end)

    {validate_us, _} =
      timed(fn ->
        for _ <- 1..@iters, do: {:ok, _} = Ex4pm.OCEL.validate_envelope(envelope)
      end)

    {ingest_us, _} =
      timed(fn ->
        for _ <- 1..@iters,
            do:
              {:ok, _} =
                AshEx4pm.ingest(events, ingest_opts: [store: nil, miner: nil])
      end)

    GenServer.stop(pid)

    %{
      n: n,
      events: event_count,
      record_us_per_event: write_us / n,
      events_us_per_event: events_us / @iters / event_count,
      export_us_per_event: export_us / @iters / event_count,
      digest_us_per_event: digest_us / @iters / event_count,
      validate_us_per_event: validate_us / @iters / event_count,
      ingest_us_per_event: ingest_us / @iters / event_count,
      mem_write_mb: mem_write / 1_048_576
    }
  end

  defp timed(f) do
    :erlang.garbage_collect()
    before_mem = :erlang.memory(:processes)
    {us, _} = :timer.tc(f)
    :erlang.garbage_collect()
    after_mem = :erlang.memory(:processes)
    {us, max(after_mem - before_mem, 0)}
  end

  defp tap_row(r) do
    IO.puts(
      "N=#{r.n} events=#{r.events}\n" <>
        "  record   #{fmt2(r.record_us_per_event)} us/event\n" <>
        "  events   #{fmt2(r.events_us_per_event)} us/event\n" <>
        "  export   #{fmt2(r.export_us_per_event)} us/event\n" <>
        "  digest   #{fmt2(r.digest_us_per_event)} us/event\n" <>
        "  validate #{fmt2(r.validate_us_per_event)} us/event\n" <>
        "  ingest   #{fmt2(r.ingest_us_per_event)} us/event"
    )

    r
  end

  defp write_json(results) do
    stamp = System.system_time(:second)
    dir = Path.join(__DIR__, "fleet")
    File.mkdir_p!(dir)

    path =
      Path.join(dir, "fleet_soak_#{stamp}.json")

    doc = %{
      generated_at: DateTime.to_iso8601(DateTime.utc_now()),
      sizes: @sizes,
      iters: @iters,
      results: results
    }

    File.write!(path, Jason.encode!(doc, pretty: true) <> "\n")
    path
  end

  defp fmt2(x), do: :erlang.float_to_binary(x * 1.0, decimals: 2)
end

Bench.FleetSoak.run()

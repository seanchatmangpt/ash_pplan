# BENCH lane: LedgerOCEL events/export/digest scaling over Store.Ets.
#
#   MIX_BUILD_ROOT=_build-ch11 MIX_ENV=test mix run bench/ocel_export_scaling.exs
#
# Measures, at checkpoints N = 1_000 / 10_000 / 50_000 (+100_000 if RUN_100K=1 and
# it completes under 5 min):
#   * record throughput  - N unique checkpoints written to the live Ets store
#   * events/3           - full event build (run_started + N task_succeeded + run_ended)
#   * export/3           - OCEL2-JSON serialization of the event list
#   * digest/3           - sha256 content digest over the events
#
# Real store only (live Ets GenServer), MIX_ENV=test, no doubles. Per-event cost is
# the linear-fit statistic: linear scaling means us/event is flat across N.
# Memory peak = :erlang.memory(:processes) delta around each phase, sampled after
# :erlang.garbage_collect().

defmodule Bench.OcelExportScaling do
  alias AshPPlan.Reactor.Durable.Store.Ets

  @sizes [1_000, 10_000, 50_000]
  @opt_size 100_000

  def run do
    sizes = if System.get_env("RUN_100K") == "1", do: @sizes ++ [@opt_size], else: @sizes

    results =
      Enum.map(sizes, fn n ->
        r = run_one(n)
        print_row(r)
        r
      end)

    print_fit(results)
    {:ok, results}
  end

  defp run_one(n) do
    {:ok, pid} = Ets.start_link()
    store = pid
    run_id = "ocel-bench-#{n}"

    {:ok, _} = Ets.start_run(store, %{id: run_id, status: :pending})

    # --- checkpoint writes -----------------------------------------------------------
    {write_us, mem_write} = timed_mem(fn ->
      Enum.each(1..n, fn i ->
        {:ok, _} = Ets.record(store, run_id, "step-#{i}", "step", {:out, i}, %{i: i})
      end)
    end)

    # terminal status so export includes run_ended
    {:ok, _} = Ets.transition(store, run_id, :any, :completed, %{})

    # --- events / export / digest -----------------------------------------------------
    # full passes are O(N), so few iterations; median of what is affordable
    iters = if n >= 50_000, do: 3, else: 5

    {events_us, mem_events} =
      timed_mem(fn ->
        Enum.each(1..iters, fn _ ->
          {:ok, evs} = AshPPlan.Reactor.Durable.LedgerOCEL.events(store, run_id)
          :persistent_term.put({__MODULE__, :event_count}, length(evs))
        end)
      end)

    event_count = :persistent_term.get({__MODULE__, :event_count})

    {export_us, mem_export} = timed_mem(fn ->
      for _ <- 1..iters do
        {:ok, _json} = AshPPlan.Reactor.Durable.LedgerOCEL.export(store, run_id)
      end
    end)

    {digest_us, mem_digest} = timed_mem(fn ->
      for _ <- 1..iters do
        {:ok, _d} = AshPPlan.Reactor.Durable.LedgerOCEL.digest(store, run_id)
      end
    end)

    GenServer.stop(pid)

    %{
      n: n,
      events: event_count,
      record_us_per_event: write_us / n,
      events_us: events_us / iters,
      events_us_per_event: events_us / iters / event_count,
      export_us: export_us / iters,
      export_us_per_event: export_us / iters / event_count,
      digest_us: digest_us / iters,
      digest_us_per_event: digest_us / iters / event_count,
      mem_write_mb: mem_write / 1_048_576,
      mem_events_mb: mem_events / 1_048_576,
      mem_export_mb: mem_export / 1_048_576,
      mem_digest_mb: mem_digest / 1_048_576
    }
  end

  # -- timing + memory ---------------------------------------------------------------

  # Runs f once (or `iters` inside f), GC before and after, returns {elapsed_us, mem_delta}
  defp timed_mem(f) do
    :erlang.garbage_collect()
    before_mem = :erlang.memory(:processes)
    {us, _} = :timer.tc(f)
    :erlang.garbage_collect()
    after_mem = :erlang.memory(:processes)
    {us, max(after_mem - before_mem, 0)}
  end

  defp print_row(r) do
    IO.puts(
      "\nN=#{r.n} events=#{r.events}\n" <>
        "  record  #{fmt0(r.record_us_per_event)} us/event  (#{fmt0(r.n * r.record_us_per_event / 1_000)} ms total)\n" <>
        "  events  #{fmt0(r.events_us)} us/pass  #{fmt2(r.events_us_per_event)} us/event  peak+#{fmt1(r.mem_events_mb)} MB\n" <>
        "  export  #{fmt0(r.export_us)} us/pass  #{fmt2(r.export_us_per_event)} us/event  peak+#{fmt1(r.mem_export_mb)} MB\n" <>
        "  digest  #{fmt0(r.digest_us)} us/pass  #{fmt2(r.digest_us_per_event)} us/event  peak+#{fmt1(r.mem_digest_mb)} MB"
    )
  end

  # -- linear fit ---------------------------------------------------------------------
  # Fit us/pass = a*N + b by least squares; report a (marginal us/event) and R^2.
  # Verdict: linear if R^2 >= 0.999 and us/event drift between smallest and largest
  # N is within +/-25%.
  defp print_fit(results) do
    IO.puts("\nlinear fit (us/pass vs N):")

    for op <- [:record, :events, :export, :digest] do
      pts = Enum.map(results, &{&1.n * 1.0, per_pass_us(&1, op) * 1.0})
      {a, b, r2} = fit(pts)
      first = Enum.at(results, 0)
      last = Enum.at(results, -1)
      us_ev_first = per_pass_us(first, op) / first.events
      us_ev_last = per_pass_us(last, op) / last.events
      drift = if us_ev_first > 0, do: (us_ev_last - us_ev_first) / us_ev_first * 100, else: 0.0

      verdict =
        if r2 >= 0.999 and abs(drift) <= 25.0, do: "LINEAR", else: "NOT-LINEAR"

      IO.puts(
        "  #{op}: us = #{fmt3(a)}*N + #{fmt0(b)}  R2=#{fmt6(r2)}  " <>
          "us/event #{fmt2(us_ev_first)} -> #{fmt2(us_ev_last)} (drift #{fmt1(drift)}%)  #{verdict}"
      )
    end
  end

  defp per_pass_us(r, :record), do: r.record_us_per_event * r.n

  defp per_pass_us(r, :events), do: r.events_us
  defp per_pass_us(r, :export), do: r.export_us
  defp per_pass_us(r, :digest), do: r.digest_us

  defp fit(pts) do
    n = length(pts)
    sx = Enum.sum(Enum.map(pts, &elem(&1, 0)))
    sy = Enum.sum(Enum.map(pts, &elem(&1, 1)))
    sxx = Enum.sum(Enum.map(pts, fn {x, _} -> x * x end))
    sxy = Enum.sum(Enum.map(pts, fn {x, y} -> x * y end))
    syy = Enum.sum(Enum.map(pts, fn {_, y} -> y * y end))

    denom = n * sxx - sx * sx

    if denom == 0 do
      {0.0, sy / n, 0.0}
    else
      a = (n * sxy - sx * sy) / denom
      b = (sy - a * sx) / n
      ss_tot = syy - sy * sy / n
      ss_res = Enum.sum(Enum.map(pts, fn {x, y} -> (y - (a * x + b)) * (y - (a * x + b)) end))
      r2 = if ss_tot == 0, do: 1.0, else: 1 - ss_res / ss_tot
      {a, b, r2}
    end
  end

  defp fmt0(x), do: :erlang.float_to_binary(x * 1.0, decimals: 0)
  defp fmt1(x), do: :erlang.float_to_binary(x * 1.0, decimals: 1)
  defp fmt2(x), do: :erlang.float_to_binary(x * 1.0, decimals: 2)
  defp fmt3(x), do: :erlang.float_to_binary(x * 1.0, decimals: 3)
  defp fmt6(x), do: :erlang.float_to_binary(x * 1.0, decimals: 6)
end

Bench.OcelExportScaling.run()

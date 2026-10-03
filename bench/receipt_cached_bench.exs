# Bench: AshPPlan.Standing.receipt_cached/2 (ETS memo) vs raw Standing.receipt/2
# across cache hit-ratio regimes, plus LRU eviction cost at steady state.
#
#   MIX_BUILD_ROOT=_build-hc4 MIX_ENV=test mix run bench/receipt_cached_bench.exs [out.json]
#
# No Benchee. Harness mirrors bench/standing_receipt_cache_probe.exs.

defmodule ReceiptCachedBench do
  @moduledoc false

  alias AshPPlan.Standing
  alias AshPPlan.Standing.Cached
  alias AshPPlan.ProcessEvidence

  @batches 7
  @opts [replay_commands: [%{cmd: "mix test", cwd: File.cwd!(), exit: 0}]]

  # -- fixture (chain_run shape from bench/standing_closure_bench.exs) -------

  @head String.duplicate("a", 40)
  @base String.duplicate("b", 40)

  defp chain_run(n, run_id \\ "r1") do
    tasks =
      for i <- 1..n do
        %{id: :"t#{i}", depends_on: (i == 1 && []) || [:"t#{i - 1}"]}
      end

    model = %{tasks: tasks}
    selection = Map.new(1..n, fn i -> {"t#{i}", :"p#{i}"} end)

    events =
      for i <- 1..n do
        %AshPPlan.ProcessEvidence.Event{
          id: "run:#{run_id}/t#{i}",
          activity: "task_succeeded",
          timestamp: ~U[2026-10-01 00:00:00Z],
          objects: [{"WorkflowRun", "run:#{run_id}", "run"}],
          attributes: %{task: "t#{i}", seq: i, provider: "p#{i}", outcome: nil},
          subject_id: "subject-1"
        }
      end

    attempts = Map.new(1..n, fn i -> {:"t#{i}", 1} end)

    %{
      run_id: run_id,
      repo: "ash_pplan",
      head: @head,
      base: @base,
      events: events,
      model: model,
      selection: selection,
      fond_gates: [],
      execution: {attempts, attempts},
      consequence: [chain_complete: true],
      observation: %{tasks_completed: n}
    }
  end

  # -- harness ----------------------------------------------------------------

  defp mean_us(reps, fun) do
    for _ <- 1..3, do: fun.()

    times =
      for _ <- 1..@batches do
        {us, _} = :timer.tc(fn -> for _ <- 1..reps, do: fun.() end)
        us / reps
      end

    Enum.sum(times) / @batches
  end

  # Harness-side cold forcing: delete the run's cache entry (identity key) so
  # the next receipt_cached/2 call is a guaranteed miss + insert.
  defp force_cold(run) do
    :ets.delete(:ash_pplan_standing_receipt_cache, Cached.identity(run, @opts))
    :ok
  end

  defp sanity(run, label) do
    {:ok, r} = Standing.receipt(run, @opts)
    {:ok, rc} = Standing.receipt_cached(run, @opts)
    true = r == rc || raise "#{label}: cached receipt not byte-identical"

    IO.puts(
      "  [sanity] #{label}: standing=#{r.standing.value} digest=#{String.slice(r.replay.ledger_digest, 0, 12)}… cached==raw ✓"
    )
  end

  def run do
    Cached.clear()

    hot_1k = chain_run(1_000, "hot1k")
    run_100 = chain_run(100, "base100")
    cold_1k = chain_run(1_000, "cold1k")

    sanity(run_100, "100ev")
    sanity(hot_1k, "1kev")

    # -- baseline: raw receipt/2 ----------------------------------------------
    raw_100_us = mean_us(100, fn -> Standing.receipt(run_100, @opts) end)
    raw_1k_us = mean_us(100, fn -> Standing.receipt(hot_1k, @opts) end)

    # -- 100% hit: same 1k run, warmed once ------------------------------------
    Standing.receipt_cached(hot_1k, @opts)
    hit_1k_us = mean_us(100, fn -> Standing.receipt_cached(hot_1k, @opts) end)

    # -- 50% hit: alternate hot (1k run) / cold (fresh 1k run, key deleted) ----
    half_us =
      mean_us(25, fn ->
        Standing.receipt_cached(hot_1k, @opts)
        Standing.receipt_cached(cold_1k, @opts)
        force_cold(cold_1k)
      end)

    half_per_call_us = half_us / 2

    # -- 0% hit: every call a miss + insert (key deleted after each call) ------
    Standing.receipt_cached(cold_1k, @opts)

    miss_1k_us =
      mean_us(25, fn ->
        Standing.receipt_cached(cold_1k, @opts)
        force_cold(cold_1k)
      end)

    # -- LRU eviction at steady state: 500-key rotation ------------------------
    # Small runs (8 events) so the measurement isolates cache machinery
    # (identity sha256 + miss scan + tab2list LRU evict) over receipt cost.
    Cached.clear()
    fillers = for i <- 1..Cached.max_entries(), do: chain_run(8, "fill#{i}")
    for r <- fillers, do: Standing.receipt_cached(r, @opts)
    true = Cached.size() == Cached.max_entries() || raise "cache not full"

    rotate = for i <- 1..500, do: chain_run(8, "rot#{i}")

    {rot_us_total, _} =
      :timer.tc(fn -> for r <- rotate, do: Standing.receipt_cached(r, @opts) end)

    rot_per_call_us = rot_us_total / 500
    true = Cached.size() == Cached.max_entries() || raise "rotation leaked entries"

    # post-rotation: original fillers fully evicted (LRU correctness spot check)
    reinsert_us = mean_us(100, fn -> Standing.receipt_cached(hd(fillers), @opts) end)

    Cached.clear()

    %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      otp: System.otp_release(),
      elixir: System.version(),
      batches: @batches,
      raw_receipt_100ev_us: Float.round(raw_100_us, 2),
      raw_receipt_1kev_us: Float.round(raw_1k_us, 2),
      cached_hit_1kev_us: Float.round(hit_1k_us, 2),
      hit_speedup_1k: Float.round(raw_1k_us / hit_1k_us, 1),
      cached_50pct_1kev_us: Float.round(half_per_call_us, 2),
      cached_0pct_1kev_us: Float.round(miss_1k_us, 2),
      miss_overhead_pct: Float.round(100 * (miss_1k_us - raw_1k_us) / raw_1k_us, 2),
      lru_rotate_500keys_us_per_call: Float.round(rot_per_call_us, 2),
      lru_refill_after_evict_us: Float.round(reinsert_us, 2),
      cache_max_entries: Cached.max_entries()
    }
  end
end

out =
  case System.argv() do
    [path | _] -> path
    _ -> nil
  end

results = ReceiptCachedBench.run()

IO.puts("""

== Standing.receipt_cached/2 vs receipt/2 (#{results.batches} batches) ==
  raw receipt/2          100ev #{results.raw_receipt_100ev_us} us | 1kev #{results.raw_receipt_1kev_us} us
  cached 100% hit (1k)   #{results.cached_hit_1kev_us} us/call  (#{results.hit_speedup_1k}x speedup)
  cached 50% hit  (1k)   #{results.cached_50pct_1kev_us} us/call avg
  cached 0% hit   (1k)   #{results.cached_0pct_1kev_us} us/call  (miss overhead #{results.miss_overhead_pct}%)
  LRU rotate 500 keys    #{results.lru_rotate_500keys_us_per_call} us/call (steady state, 8ev receipts)
  refill after evict     #{results.lru_refill_after_evict_us} us/call
""")

if out do
  File.write!(out, Jason.encode!(results))
  IO.puts("wrote #{out}")
end

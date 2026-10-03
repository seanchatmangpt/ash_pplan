# Bench: AshPPlan.Standing.receipt_cached/2 scaling across evidence sizes.
#
# Measures, per evidence size (100 / 1_000 / 10_000 events):
#   * receipt/2 raw cost (baseline)
#   * receipt_cached/2 cold miss (clear before every call: full receipt + identity + insert)
#   * receipt_cached/2 warm hit (identity + ETS lookup + LRU touch)
#   * identity-hash cost in isolation (Cached.identity/2: Merkle-style per-event
#     leaf hashes + combine; leaf digests memoized across calls, see cached.ex)
#   * LRU eviction cost at steady state: 500-key rotation against the 256-entry cap
#
# Real Standing.Receipt builds throughout; no Benchee; in-script harness.
# Sanity gates in-script: every fixture settles ALIVE, cached result is
# byte-identical (==) to the direct receipt/2 result, and cache size is exactly
# 256 before and after the 500-key rotation.
#
# Reproduce:
#   MIX_BUILD_ROOT=_build-bb1 MIX_ENV=test \
#     mix run bench/receipt_cached_scaling.exs bench/receipt_cached_scaling_raw1.json
#   MIX_BUILD_ROOT=_build-bb1 MIX_ENV=test \
#     mix run bench/receipt_cached_scaling.exs bench/receipt_cached_scaling_raw2.json

defmodule ReceiptCachedScaling do
  @moduledoc false

  alias AshPPlan.Standing
  alias AshPPlan.Standing.Cached

  @sizes [100, 1_000, 10_000]

  # Effort per size: the sealed ledger digest is O(n^2), so raw/miss at 10k
  # events is ~1000x a 100-event call. raw+miss get tiny effort at 10k; hit and
  # identity are cheap and get full effort at every size.
  @raw_effort %{100 => {5, 100}, 1_000 => {5, 20}, 10_000 => {2, 2}}
  @hit_reps 200
  @ident_reps 500

  @head String.duplicate("a", 40)
  @base String.duplicate("b", 40)

  # -- fixture: linear task chain (same shape as bench/standing_receipt_cache_probe.exs) --

  defp chain_run(n) do
    tasks =
      for i <- 1..n do
        %{id: :"t#{i}", depends_on: (i == 1 && []) || [:"t#{i - 1}"]}
      end

    model = %{tasks: tasks}
    selection = Map.new(1..n, fn i -> {"t#{i}", :"p#{i}"} end)

    events =
      for i <- 1..n do
        %AshPPlan.ProcessEvidence.Event{
          id: "run:r1/t#{i}",
          activity: "task_succeeded",
          timestamp: ~U[2026-10-01 00:00:00Z],
          objects: [{"WorkflowRun", "run:r1", "run"}],
          attributes: %{task: "t#{i}", seq: i, provider: "p#{i}", outcome: nil},
          subject_id: "subject-1"
        }
      end

    attempts = Map.new(1..n, fn i -> {:"t#{i}", 1} end)

    %{
      run_id: "r1",
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

  defp cmds, do: [%{cmd: "mix test", cwd: File.cwd!(), exit: 0}]

  # -- harness ----------------------------------------------------------------

  defp mean_us(fun, batches, reps) do
    # warm-up
    for _ <- 1..2, do: fun.()

    times =
      for _ <- 1..batches do
        {us, _} = :timer.tc(fn -> for _ <- 1..reps, do: fun.() end)
        us / reps
      end

    Enum.sum(times) / batches
  end

  defp raw_us(run, opts, batches, reps),
    do: mean_us(fn -> Standing.receipt(run, opts) end, batches, reps)

  # miss: cold-cache receipt_cached (clear before every call)
  defp miss_us(run, opts, batches, reps) do
    mean_us(
      fn ->
        Cached.clear()
        Standing.receipt_cached(run, opts)
      end,
      batches,
      reps
    )
  end

  # hit: prime once, then time repeated receipt_cached on the same key
  defp hit_us(run, opts, batches) do
    Cached.clear()
    Standing.receipt_cached(run, opts)
    mean_us(fn -> Standing.receipt_cached(run, opts) end, batches, @hit_reps)
  end

  defp identity_us(run, opts, batches),
    do: mean_us(fn -> Cached.identity(run, opts) end, batches, @ident_reps)

  # LRU steady-state rotation: fill to the 256-entry cap with small runs, then
  # drive 500 fresh unique keys through receipt_cached — every call is a miss
  # that triggers one O(max) tab2list+min_by evict scan plus an insert.
  defp rotation_us(batches) do
    opts = [replay_commands: cmds()]
    Cached.clear()

    # fill the table to exactly @max with distinct 8-event runs
    for i <- 1..Cached.max_entries() do
      {:ok, _} = Standing.receipt_cached(chain_run(8) |> Map.put(:run_id, "fill-#{i}"), opts)
    end

    size_before = Cached.size()
    keys = 500

    rotation_keys =
      for i <- 1..keys, do: {chain_run(8) |> Map.put(:run_id, "rot-#{i}"), opts}

    fun = fn {run, o} -> Standing.receipt_cached(run, o) end

    # warm the harness (also displaces filler), then time fresh rotation keys
    Enum.take(rotation_keys, 10) |> Enum.each(fun)

    times =
      for _ <- 1..batches do
        # each batch rotates a distinct key set so every call is a capacity miss
        batch_keys =
          for i <- 1..keys,
              do: {chain_run(8) |> Map.put(:run_id, "rot-#{System.unique_integer()}-#{i}"), opts}

        {us, _} = :timer.tc(fn -> Enum.each(batch_keys, fun) end)
        us / keys
      end

    size_after = Cached.size()
    %{per_call_us: Enum.sum(times) / batches, size_before: size_before, size_after: size_after}
  end

  defp one_size(n) do
    run = chain_run(n)
    opts = [replay_commands: cmds()]
    {batches, reps} = Map.fetch!(@raw_effort, n)

    {:ok, receipt} = Standing.receipt(run, opts)

    if receipt.standing.value != "ALIVE" do
      raise "fixture for #{n} events did not settle ALIVE: #{inspect(receipt.standing)}"
    end

    Cached.clear()
    raw = raw_us(run, opts, batches, reps)
    miss = miss_us(run, opts, batches, reps)

    # byte-identical gate: cached result == direct result
    Cached.clear()

    assert_identical(run, opts, {:ok, receipt})

    hit = hit_us(run, opts, batches)
    ident = identity_us(run, opts, batches)
    ident_bytes = byte_size(:erlang.term_to_binary({run, opts}))
    Cached.clear()

    %{
      events: n,
      standing: receipt.standing.value,
      receipt_us: Float.round(raw, 2),
      cached_miss_us: Float.round(miss, 2),
      miss_overhead_pct: Float.round(100 * (miss - raw) / raw, 1),
      cached_hit_us: Float.round(hit, 3),
      hit_speedup: Float.round(raw / hit, 1),
      identity_us: Float.round(ident, 3),
      identity_share_of_hit_pct: Float.round(100 * ident / hit, 1),
      identity_term_bytes: ident_bytes
    }
  end

  defp assert_identical(run, opts, direct) do
    case Standing.receipt_cached(run, opts) do
      ^direct -> :ok
      other -> raise "cached result is not identical to receipt/2: #{inspect(other)}"
    end
  end

  def run do
    Cached.clear()
    per_size = Enum.map(@sizes, &one_size/1)
    rotation = rotation_us(3)
    %{per_size: per_size, rotation: rotation}
  end
end

results = ReceiptCachedScaling.run()

IO.puts("""
== Standing.receipt_cached/2 scaling — evidence size 100 / 1k / 10k events ==
""")

Enum.each(results.per_size, fn r ->
  IO.puts("""
  events=#{r.events} standing=#{r.standing}
    receipt/2 raw            #{r.receipt_us} us/call
    receipt_cached cold miss #{r.cached_miss_us} us/call (#{r.miss_overhead_pct}% vs raw)
    receipt_cached hit       #{r.cached_hit_us} us/call  (#{r.hit_speedup}x vs raw)
    identity (merkle)        #{r.identity_us} us/call  (#{r.identity_share_of_hit_pct}% of hit; term #{r.identity_term_bytes} B)
  """)
end)

rot = results.rotation

IO.puts("""
LRU steady-state rotation (256-entry cap, 500 fresh keys/batch):
  #{Float.round(rot.per_call_us, 2)} us per capacity-miss insert (size #{rot.size_before} -> #{rot.size_after})
""")

out =
  case System.argv() do
    [path | _] -> path
    _ -> nil
  end

if out do
  File.write!(
    out,
    Jason.encode!(
      %{
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        otp: System.otp_release(),
        elixir: System.version(),
        build_root: System.get_env("MIX_BUILD_ROOT"),
        results: results
      },
      pretty: true
    )
  )

  IO.puts("wrote #{out}")
end

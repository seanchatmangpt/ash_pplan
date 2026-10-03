# Bench: Standing.receipt_cached/2 vs Standing.receipt/2 across evidence sizes.
#
# For each size (100 / 1k / 10k events):
#   * raw (miss) cost of receipt_cached/2 — receipt/2 work + identity + insert
#   * cached-hit cost — identity (term_to_binary + sha256) + ETS lookup
#   * hit speedup vs receipt/2
#   * identity-hash overhead growth — is term_to_binary+sha256 itself non-trivial at 10k events?
#
#   MIX_BUILD_ROOT=_build-b1b MIX_ENV=test mix run bench/receipt_cache_scaling.exs [out.json]
#
# No Benchee. Harness mirrors bench/standing_receipt_cache_probe.exs.

defmodule ReceiptCacheScaling do
  @moduledoc false

  alias AshPPlan.Standing
  alias AshPPlan.Standing.Cached

  @sizes [100, 1_000, 10_000]

  # Per-size effort: raw receipt is now ~linear in events (chain digest via
  # Chain.build_sealed/4 and plan_correct/1 are O(n)), but identity hashing and
  # evidence export keep 10k-event calls ~100x a 100-event call. Effort scaled
  # to keep each size's measurement under ~2 minutes.
  @effort %{100 => {5, 100}, 1_000 => {5, 20}, 10_000 => {3, 3}}

  @head String.duplicate("a", 40)
  @base String.duplicate("b", 40)

  # -- fixture (chain_run shape from bench/standing_receipt_cache_probe.exs) --

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
    # warmup (also primes the cache for the hit measurement)
    for _ <- 1..2, do: fun.()

    times =
      for _ <- 1..batches do
        {us, _} = :timer.tc(fn -> for _ <- 1..reps, do: fun.() end)
        us / reps
      end

    Enum.sum(times) / batches
  end

  # miss cost: cold-cache receipt_cached — clear before each call
  defp miss_us(run, opts, batches, reps) do
    fun = fn ->
      Cached.clear()
      Standing.receipt_cached(run, opts)
    end

    mean_us(fun, batches, reps)
  end

  defp identity_us(run, opts, batches, reps),
    do: mean_us(fn -> Cached.identity(run, opts) end, batches, max(reps, 50))

  defp size_bytes(x) when is_binary(x), do: byte_size(x)
  defp size_bytes(_), do: nil

  defp one_size(n) do
    run = chain_run(n)
    opts = [replay_commands: cmds()]
    {batches, reps} = Map.fetch!(@effort, n)

    {:ok, receipt} = Standing.receipt(run, opts)
    Cached.clear()

    raw_us = mean_us(fn -> Standing.receipt(run, opts) end, batches, reps)
    miss_us = miss_us(run, opts, batches, reps)
    Cached.clear()
    Standing.receipt_cached(run, opts)
    hit_us = mean_us(fn -> Standing.receipt_cached(run, opts) end, batches, max(reps, 50))
    ident_us = identity_us(run, opts, batches, reps)
    ident_bytes = size_bytes(:erlang.term_to_binary({run, opts}))

    %{
      events: n,
      standing: receipt.standing.value,
      receipt_us: Float.round(raw_us, 2),
      cached_miss_us: Float.round(miss_us, 2),
      cached_hit_us: Float.round(hit_us, 3),
      hit_speedup: Float.round(raw_us / hit_us, 1),
      identity_us: Float.round(ident_us, 3),
      identity_share_of_hit_pct: Float.round(100 * ident_us / hit_us, 1),
      identity_term_bytes: ident_bytes,
      hit_speedup_vs_miss: Float.round(miss_us / hit_us, 1)
    }
  end

  def run do
    Cached.clear()
    Enum.map(@sizes, &one_size/1)
  end

  def shape, do: @effort
end

results = ReceiptCacheScaling.run()
effort = ReceiptCacheScaling.shape()

IO.puts("""
== Standing.receipt_cached/2 vs receipt/2 scaling — adaptive effort #{inspect(effort)} ==
""")

Enum.each(results, fn r ->
  IO.puts("""
  events=#{r.events} standing=#{r.standing}
    receipt/2 (raw)          #{r.receipt_us} us/call
    receipt_cached cold miss #{r.cached_miss_us} us/call
    receipt_cached hit       #{r.cached_hit_us} us/call  (#{r.hit_speedup}x vs raw)
    identity (t2b+sha256)    #{r.identity_us} us/call  (#{r.identity_share_of_hit_pct}% of hit; term #{r.identity_term_bytes} B)
  """)
end)

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
        effort:
          ReceiptCacheScaling.shape()
          |> Enum.map(fn {n, {b, r}} -> %{events: n, batches: b, reps: r} end),
        results: results
      },
      pretty: true
    )
  )

  IO.puts("wrote #{out}")
end

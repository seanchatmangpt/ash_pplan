defmodule AshPPlan.Standing.ReceiptCachedStormTest do
  @moduledoc """
  STRESS lane: storm `Standing.receipt_cached/2` (`Standing.Cached`) under a mixed
  access profile concurrent with LRU eviction churn — no mocks, the ETS cache and the
  pure standing functions are the real collaborators and the race window is the subject.

  Topology (16 processes, one ExUnit test):

    * 16 storm processes x 400 iterations each, mixing per iteration:
      - 60% hot keys: one of 8 fixed runs (shared across all processes)
      - 30% warm-miss keys: one of 64 rotating runs (larger than the cache, so warm
        entries get evicted between visits and recompute)
      - 10% cold unique runs: freshly minted per call (always miss, always evict)
    * The cold/warm traffic keeps `evict_lru/0` firing continuously while hot keys
      are re-touched, so hot-key byte-identity and the cache bound are asserted
      under concurrent eviction pressure, not against a quiescent table.

  Courts:
    1. hot-key determinism: every iteration, each hot run's `receipt_cached/2` result
       is byte-identical (via `:erlang.term_to_binary`) to the process's first
       observation of that hot run.
    2. typed results only: every call returns `{:ok, %Receipt{}}` or `{:error, map}`,
       or is a `catch` (recorded as a fault) — no untyped escape.
    3. cache bound: `Cached.size/0` sampled after each call never exceeds 256
       (`Cached.max_entries/0`).
    4. process memory bound: per-process heap delta < 50 MB.
    5. total wall time bounded: the whole storm is @tag timeout: 600_000 and the
       reported duration must beat it with headroom.
  """

  use ExUnit.Case, async: false

  @moduletag :stress

  alias AshPPlan.Standing
  alias AshPPlan.Standing.Cached

  @procs 16
  @iters 400
  @hot 8
  @warm 64
  @mem_limit_bytes 50 * 1024 * 1024

  @head String.duplicate("a", 40)
  @base String.duplicate("b", 40)

  @model %{
    tasks: [
      %{id: :admit, depends_on: []},
      %{id: :pay, depends_on: [:admit]},
      %{id: :ship, depends_on: [:pay]}
    ]
  }

  # ---- run builders (same legal input space as the churn lane) ----

  defp ev(subject, task, seq, provider, outcome \\ nil) do
    %AshPPlan.ProcessEvidence.Event{
      id: "run:#{subject}/#{task}",
      activity: "task_succeeded",
      timestamp: ~U[2026-10-01 00:00:00Z],
      objects: [{"WorkflowRun", "run:#{subject}", "run"}],
      attributes: %{task: task, seq: seq, provider: provider, outcome: outcome},
      subject_id: subject
    }
  end

  defp build_run(subject, pay_outcome, drift?, fail?, obs \\ %{shipments: 1}) do
    events = [
      ev(subject, "admit", 1, "p1", nil),
      ev(subject, "pay", 2, "p2", pay_outcome),
      ev(subject, "ship", 3, "p3")
    ]

    execution = if drift?, do: {%{pay: 2}, %{pay: 1}}, else: {%{pay: 1}, %{pay: 1}}

    consequence =
      if fail?, do: [order_fulfilled: false, one_shipment: true], else: [order_fulfilled: true]

    %{
      run_id: "r-#{subject}",
      repo: "ash_pplan",
      head: @head,
      base: @base,
      events: events,
      model: @model,
      selection: %{admit: :p1, pay: :p2, ship: :p3},
      fond_gates: [%{task: "pay", admit: ["authorized", "declined"], successors: ["ship"]}],
      execution: execution,
      consequence: consequence,
      observation: obs
    }
  end

  # 8 fixed hot runs shared by every process — identical terms, identical cache keys.
  defp hot_runs do
    for w <- 1..@hot do
      {pay, drift, fail} =
        case rem(w, 4) do
          0 -> {"authorized", false, false}
          1 -> {"authorized", true, false}
          2 -> {"declined", false, false}
          _ -> {"authorized", false, true}
        end

      build_run("hot-#{w}", pay, drift, fail)
    end
  end

  # 64 warm runs (rotating) — more than the 256-entry cache never holds of them once
  # cold traffic churns, so warm keys oscillate hit/miss.
  defp warm_run(n), do: build_run("warm-#{rem(n, @warm)}", "authorized", rem(n, 2) == 0, false)

  defp cold_run(n, w),
    do: build_run("cold-#{w}-#{n}", "authorized", rem(n, 3) == 0, rem(n, 5) == 4)

  # ---- typed-error wrapper ----

  defp typed(fun) do
    fun.()
  catch
    :exit, reason -> {:typed_exit, reason}
    class, reason -> {:typed_error, class, reason}
  end

  defp fault(results, term), do: Agent.get_and_update(results, fn l -> {:ok, [term | l]} end)

  defp pct(sorted, p) do
    idx = max(0, ceil(p / 100 * length(sorted)) - 1)
    Enum.fetch!(sorted, idx)
  end

  # ---- the storm worker ----

  defp storm_loop(hot, results, latencies, w) do
    # per-process first observation of each hot run = the reference receipts
    hot_ref =
      Map.new(Enum.with_index(hot), fn {run, i} ->
        case Standing.receipt_cached(run, replay_commands: replay_cmds()) do
          {:ok, r} -> {i, :erlang.term_to_binary(r)}
          {:error, e} -> {i, {:err, :erlang.term_to_binary(e)}}
        end
      end)

    mem0 = :erlang.process_info(self(), [:memory])[:memory]

    for i <- 1..@iters do
      t0 = :erlang.monotonic_time(:millisecond)
      roll = rem(i, 10)

      {run, hot_idx} =
        cond do
          roll < 6 -> {Enum.at(hot, rem(i, @hot)), rem(i, @hot)}
          roll < 9 -> {warm_run(i + w * @iters), nil}
          true -> {cold_run(i, w), nil}
        end

      result = typed(fn -> Standing.receipt_cached(run, replay_commands: replay_cmds()) end)

      case result do
        {:ok, r} ->
          bin = :erlang.term_to_binary(r)

          if hot_idx != nil do
            ref = Map.fetch!(hot_ref, hot_idx)

            if bin != ref do
              fault(results, {:hot_key_drift, w, i, hot_idx})
            end
          end

        {:error, e} when is_map(e) ->
          if hot_idx != nil do
            ref = Map.fetch!(hot_ref, hot_idx)

            if {:err, :erlang.term_to_binary(e)} != ref do
              fault(results, {:hot_key_drift_err, w, i, hot_idx})
            end
          end

        {:error, other} ->
          fault(results, {:untyped_error, w, i, other})

        {:typed_error, class, reason} ->
          fault(results, {:raised, w, i, class, reason})

        {:typed_exit, reason} ->
          fault(results, {:exited, w, i, reason})

        other ->
          fault(results, {:bad_shape, w, i, other})
      end

      size = Cached.size()

      if size > Cached.max_entries() do
        fault(results, {:cache_overbound, w, i, size})
      end

      dt = :erlang.monotonic_time(:millisecond) - t0
      Agent.update(latencies, fn l -> [dt | l] end)
    end

    mem1 = :erlang.process_info(self(), [:memory])[:memory]
    {mem1 - mem0, hot_ref}
  end

  defp replay_cmds,
    do: [%{cmd: "mix test test/stress/receipt_cached_storm_test.exs", cwd: File.cwd!(), exit: 0}]

  # ---- the court ----

  @tag :stress
  @tag timeout: 600_000
  test "receipt_cached storm: 16x400 mixed-profile calls under LRU eviction churn" do
    Cached.clear()
    hot = hot_runs()
    {:ok, results} = Agent.start_link(fn -> [] end)
    {:ok, latencies} = Agent.start_link(fn -> [] end)
    t0 = :erlang.monotonic_time(:millisecond)

    workers =
      for w <- 1..@procs do
        Task.async(fn -> storm_loop(hot, results, latencies, w) end)
      end

    outs = Task.await_many(workers, 590_000)
    wall_ms = :erlang.monotonic_time(:millisecond) - t0
    total_calls = @procs * @iters

    faults = Agent.get(results, & &1)
    lats = Agent.get(latencies, & &1) |> Enum.sort()
    max_mem_delta = outs |> Enum.map(fn {d, _} -> d end) |> Enum.max()
    max_size_seen = Cached.size()

    IO.puts("""
    receipt_cached storm: #{total_calls} calls, #{length(hot) * @procs} hot refs
      wall: #{wall_ms} ms  throughput: #{Float.round(total_calls / max(wall_ms, 1) * 1000, 0)} calls/s
      latency ms  p50: #{pct(lats, 50)}  p90: #{pct(lats, 90)}  p99: #{pct(lats, 99)}  max: #{List.last(lats)}
      cache size (final): #{max_size_seen}/#{Cached.max_entries()}
      max per-process memory delta: #{div(max_mem_delta, 1024)} KB
      faults: #{length(faults)}
    """)

    assert faults == [], "faults: #{inspect(Enum.take(faults, 10), limit: 10)}"
    assert length(lats) == total_calls
    assert max_size_seen <= Cached.max_entries()

    assert max_mem_delta < @mem_limit_bytes,
           "process memory delta #{max_mem_delta} bytes exceeds limit"

    assert wall_ms < 600_000
  end
end

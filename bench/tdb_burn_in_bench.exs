# TDB burn-in baseline benchmarks (2026-10-03).
#
#   MIX_BUILD_ROOT=_build-tdb-b1 MIX_ENV=test mix run bench/tdb_burn_in_bench.exs [out.json]
#
# No Benchee (not a dependency; none added). Same in-script timing harness as
# bench/hot_paths_bench.exs: warm-up, seven timed batches, ips + mean
# microseconds per op + stddev.
#
# Measures:
#   1. SA2A.Provider propose latency (real FOND) at domain sizes 10 / 100 states
#   2. Compiler duplicate-step fence decision cost at 200 concurrent duplicates
#      (all 200 steps share one IRI; baseline: 200 unique steps)
#   3. Petri-net alignment cost per trace at trace lengths 4 / 16 / 64.
#      test/support/tokyo_depeg/alignment.ex exists on disk but is truncated/
#      corrupt (its `lifecycle/0` body is garbled and does not compile), so the
#      classic uniform-cost (Dijkstra) alignment is implemented inline here
#      over the same 5-transition lifecycle chain.
#   4. LedgerOCEL events/export/digest at 1k / 10k events (Ets store)

defmodule TdbBench do
  @moduledoc false

  @batches 7

  def measure(name, n, fun) do
    for _ <- 1..min(n, 50), do: fun.()

    {times_us, ips_list} =
      for _ <- 1..@batches do
        {us, _} = :timer.tc(fn -> for _ <- 1..n, do: fun.() end)
        {us / n, n / (us / 1_000_000)}
      end
      |> Enum.unzip()

    mean_us = Enum.sum(times_us) / @batches
    ips = Enum.sum(ips_list) / @batches

    var =
      Enum.reduce(times_us, 0, fn t, acc -> acc + (t - mean_us) * (t - mean_us) end) /
        (@batches - 1)

    stddev_us = :math.sqrt(var)

    %{
      name: name,
      ips: Float.round(ips, 1),
      mean_us: Float.round(mean_us, 2),
      stddev_us: Float.round(stddev_us, 2),
      stddev_pct: Float.round(100 * stddev_us / mean_us, 1)
    }
  end

  # -- 1. FOND propose fixtures ----------------------------------------------

  def fond_domain(n_states) do
    transitions =
      for i <- 0..(n_states - 1), into: %{} do
        # nondeterministic edge: advance may park back in s0 (strong-refused,
        # strong-cyclic-admitted) -- a real FOND domain, not a trivial chain
        next = :"s#{i + 1}"
        {:"s#{i}", %{advance: [next, :s0]}}
      end

    goals = MapSet.new([:"s#{n_states}"])
    {:ok, domain} = AshPPlan.FOND.new(transitions, goals)
    domain
  end

  def fond_request(domain, initial) do
    %{
      formalism: :fond,
      subject: "repo/ash_pplan bench/#{System.unique_integer([:positive])}",
      domain: domain,
      initial: initial
    }
  end

  # -- 2. duplicate fence fixtures --------------------------------------------

  def plan_spec(n_steps, iri_fun) do
    %{
      iri: "plan:tdb_bench_#{System.unique_integer([:positive])}",
      steps:
        for i <- 1..n_steps do
          %{
            iri: iri_fun.(i),
            predecessors: if(i == 1, do: [], else: ["step:#{i - 1}"]),
            inputs: ["in:#{i}"],
            outputs: ["out:#{i}"]
          }
        end
    }
  end

  # -- 3. Petri-net alignment (uniform-cost / Dijkstra, inline) ---------------

  defmodule Petri do
    @moduledoc false
    # Chain lifecycle: p0 -t0-> p1 -t1-> p2 -t2-> p3 -t3-> p4 -t4-> p5
    # Labels mirror the Tokyo depeg lifecycle shape.

    @labels ["risk_preflight", "collateral_check", "sanctions_screen", "execution", "settle"]

    def labels, do: @labels

    def transitions do
      %{t0: "risk_preflight", t1: "collateral_check", t2: "sanctions_screen", t3: "execution", t4: "settle"}
    end

    @initial :p0
    @final :p5

    # Synchronous-product alignment: state = {place, trace_index}.
    # sync move (label matches) cost 0; log move cost 1; model move cost 1.
    def align(trace) when is_list(trace) do
      labels = Map.values(transitions())

      dijkstra(
        {@initial, 0},
        fn {p, i} -> p == @final and i == length(trace) end,
        fn {p, i} = node ->
          moves = []

          moves =
            if i < length(trace) do
              [
                # log move
                {{p, i + 1}, 1}
                | moves
              ]
            else
              moves
            end

          moves =
            case model_moves(p) do
              [] ->
                moves

              tms ->
                Enum.map(tms, fn {p2, cost} -> {{p2, i}, cost} end) ++
                  Enum.flat_map(tms, fn {p2, cost} ->
                    if i < length(trace) and Enum.at(trace, i) in labels do
                      # synchronous move
                      [{{p2, i + 1}, cost}]
                    else
                      []
                    end
                  end)
            end

          moves
        end
      )
    end

    defp model_moves(:p0), do: [{:p1, 1}]
    defp model_moves(:p1), do: [{:p2, 1}]
    defp model_moves(:p2), do: [{:p3, 1}]
    defp model_moves(:p3), do: [{:p4, 1}]
    defp model_moves(:p4), do: [{:p5, 1}]
    defp model_moves(:p5), do: []

    defp tl2(q) do
      case :gb_sets.size(q) do
        0 -> q
        _ ->
          {_, rest} = :gb_sets.take_smallest(q)
          rest
      end
    end

    defp dijkstra(source, goal?, neighbors) do
      dist = %{source => 0}
      queue = :gb_sets.singleton({0, source})

      dijkstra(queue, %{}, dist, goal?, neighbors)
    end

    defp dijkstra(queue, settled, dist, goal?, neighbors) do
      case :gb_sets.smallest(queue) do
        {_d, node} ->
          case Map.has_key?(settled, node) do
            true ->
              dijkstra(tl2(queue), settled, dist, goal?, neighbors)

            false ->
              if goal?.(node) do
                {:ok, Map.fetch!(dist, node)}
              else
                settled2 = Map.put(settled, node, true)
                queue2 = tl2(queue)

                {queue3, dist2} =
                  Enum.reduce(neighbors.(node), {queue2, dist}, fn {n2, w}, {q, dd} ->
                    nd = Map.fetch!(dist, node) + w

                    if nd < Map.get(dd, n2, :infinity) do
                      {:gb_sets.add_element({nd, n2}, q), Map.put(dd, n2, nd)}
                    else
                      {q, dd}
                    end
                  end)

                dijkstra(queue3, settled2, dist2, goal?, neighbors)
              end
          end
      end
    end
  end

  def trace(len, good_ratio) do
    labels = Petri.labels()

    for i <- 1..len do
      if rem(i, good_ratio) == 0, do: "unexpected_#{i}", else: Enum.at(labels, rem(i, 5))
    end
  end

  # -- 4. LedgerOCEL fixtures --------------------------------------------------

  def fresh_store(name_base) do
    name = :"#{name_base}_#{System.unique_integer([:positive])}"
    {:ok, store} = AshPPlan.Reactor.Durable.Store.Ets.start_link(name: name)
    store
  end

  defmodule NoopStep do
    @moduledoc false
    use Reactor.Step

    @impl true
    def run(_arguments, _context, _options), do: {:ok, :noop}
  end
end

alias AshPPlan.Compiler
alias AshPPlan.Reactor.Durable.LedgerOCEL
alias AshPPlan.Reactor.Durable.Store.Ets
alias AshPPlan.SA2A.Provider
alias TdbBench, as: B

rows = []

# ---------------------------------------------------------------------------
# 1. SA2A.Provider propose (real FOND synthesis) at corpus sizes 10 / 100
rows =
  for n <- [10, 100], reduce: rows do
    acc ->
      domain = B.fond_domain(n)
      {:ok, _} = Provider.propose(B.fond_request(domain, :s0), [])

      [
        B.measure("sa2a_propose_fond_states_#{n}", 100, fn ->
          {:ok, _} = Provider.propose(B.fond_request(domain, :s0), [])
          :ok
        end)
        | acc
      ]
  end

# ---------------------------------------------------------------------------
# 2. Duplicate-step fence decision at 200 concurrent duplicates
dup_spec = B.plan_spec(200, fn _i -> "step:dup" end)
uniq_spec = B.plan_spec(200, fn i -> "step:#{i}" end)
handlers = Map.new(uniq_spec.steps, &{&1.iri, B.NoopStep})

# sanity: the fence must fire and the unique plan must compile once
case Compiler.compile_spec(dup_spec, handlers) do
  {:error, %AshPPlan.Compiler.Error{reason: :duplicate_steps}} -> :ok
  other -> raise "duplicate fence did not fire: #{inspect(other, limit: 5)}"
end

{:ok, _} = Compiler.compile_spec(uniq_spec, handlers)

rows = [
  B.measure("compiler_duplicate_fence_200_dups", 500, fn ->
    {:error, %AshPPlan.Compiler.Error{reason: :duplicate_steps}} = Compiler.compile_spec(dup_spec, handlers)
    :ok
  end)
  | rows
]

rows = [
  B.measure("compiler_no_fence_200_unique", 500, fn ->
    {:ok, _} = Compiler.compile_spec(uniq_spec, handlers)
    :ok
  end)
  | rows
]

# ---------------------------------------------------------------------------
# 3. Petri-net alignment per trace at lengths 4 / 16 / 64
rows =
  for len <- [4, 16, 64], reduce: rows do
    acc ->
      tr = B.trace(len, 4)
      {:ok, cost} = B.Petri.align(tr)

      if not (is_integer(cost) and cost > 0) do
        raise "bad alignment cost #{inspect(cost)}"
      end

      [
        B.measure("petri_align_trace_len_#{len}", 200, fn ->
          {:ok, _} = B.Petri.align(tr)
          :ok
        end)
        | acc
      ]
  end

# ---------------------------------------------------------------------------
# 4. LedgerOCEL export + digest at 1k / 10k events
store = B.fresh_store("tdb_ocel")

rows =
  for n_events <- [1_000, 10_000], reduce: rows do
    rows ->
      run_id = "tdb_ocel_#{n_events}"
      {:ok, _} = AshPPlan.Reactor.Durable.Engine.start(store, %{id: run_id, effects: "none", steps: []})

      for i <- 1..n_events do
        {:ok, _} =
          Ets.record(store, run_id, "k#{i}", "step#{rem(i, 8)}", %{v: i, blob: String.duplicate("x", 64)}, %{})
      end

      {:ok, events} = LedgerOCEL.events(store, run_id)
      :ok = if length(events) == n_events + 1, do: :ok, else: raise("bad event count #{length(events)}")

      rows ++
        [
        B.measure("ledger_ocel_events_#{n_events}", max(10, div(20_000, n_events)), fn ->
          {:ok, evs} = LedgerOCEL.events(store, run_id)
          :ok = if length(evs) == n_events + 1, do: :ok, else: raise("bad count")
        end),
        B.measure("ledger_ocel_export_#{n_events}", max(5, div(10_000, n_events)), fn ->
          {:ok, json} = LedgerOCEL.export(store, run_id)
          :ok = if byte_size(json) > 1_000, do: :ok, else: raise("bad export")
        end),
        B.measure("ledger_ocel_digest_#{n_events}", max(10, div(20_000, n_events)), fn ->
          {:ok, d} = LedgerOCEL.digest(store, run_id)
          :ok = if byte_size(d) == 64, do: :ok, else: raise("bad digest")
        end)
      ]
  end

rows = Enum.reverse(rows)

doc = %{
  schema: "ash_pplan/tdb-burn-in-bench/1",
  date: "2026-10-03",
  otp: System.otp_release(),
  elixir: System.version(),
  system: :erlang.system_info(:system_architecture) |> to_string(),
  schedulers: System.schedulers_online(),
  rows: rows
}

json = JSON.encode!(doc)
IO.puts(json)

case System.argv() do
  [path] -> File.write!(path, json)
  _ -> :ok
end

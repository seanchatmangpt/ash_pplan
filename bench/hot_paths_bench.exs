# Hot-path benchmarks: Durable.Engine attempt/signal cycle, checkpoint write
# (Ets vs Dets), Standing.Receipt, LedgerOCEL export of a 1k-event ledger,
# FOND policy evaluation.
#
#   MIX_BUILD_ROOT=_build-bench1 MIX_ENV=test mix run bench/hot_paths_bench.exs [out.json]
#
# No Benchee (not a dependency; none added). The harness warms up, runs seven
# timed batches, and reports ips, mean microseconds per op, stddev, and
# retained-process memory per op (spawned-process memory delta / n; a lower
# bound on real allocation).

defmodule HotPathsBench do
  @moduledoc false

  alias AshPPlan.Durable.LaneBFx
  alias AshPPlan.Reactor.Durable.Store.{Dets, Ets}

  # -- harness ---------------------------------------------------------------

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
    mem = mem_per_op(fun, n)

    %{
      name: name,
      ips: Float.round(ips, 1),
      mean_us: Float.round(mean_us, 2),
      stddev_us: Float.round(stddev_us, 2),
      stddev_pct: Float.round(100 * stddev_us / mean_us, 1),
      mem_bytes_per_op: mem
    }
  end

  defp mem_per_op(fun, n) do
    parent = self()

    spawn_link(fn ->
      :erlang.garbage_collect()
      before_mem = :erlang.process_info(self(), :memory) |> elem(1)
      for _ <- 1..n, do: fun.()
      :erlang.garbage_collect()
      after_mem = :erlang.process_info(self(), :memory) |> elem(1)
      send(parent, {:mem, max(0, after_mem - before_mem)})
      Process.sleep(:infinity)
    end)

    mem =
      receive do
        {:mem, delta} -> Float.round(delta / n, 2)
      after
        120_000 -> :timeout
      end

    :erlang.garbage_collect()
    mem
  end

  # -- fixtures --------------------------------------------------------------

  def fresh_store(name_base) do
    name = :"#{name_base}_#{System.unique_integer([:positive])}"
    {:ok, store} = Ets.start_link(name: name)
    {store, name}
  end

  def with_dets(fun) do
    path = Path.join(System.tmp_dir!(), "bench_dets_#{System.unique_integer([:positive])}")
    {:ok, store} = Dets.start_link(path: path)

    try do
      fun.(store)
    after
      GenServer.stop(store)
      File.rm(path <> ".dets")
      File.rm(path)
    rescue
      _ -> :ok
    end
  end

  def effects_name, do: :"bench_effects_#{System.unique_integer([:positive])}"

  def complete_run_attrs(fx, id) do
    %{LaneBFx.attrs(id, fx) | inputs: %{frontier: [%{id: :a, status: :open, deps: []}]}}
  end

  def parked_run_attrs(fx, id) do
    LaneBFx.attrs(id, fx, kinds: %{verify: :await})
  end
end

Code.require_file("lane_b_fixture.exs", Path.expand("../test/durable", __DIR__))

alias AshPPlan.Durable.LaneBFx
alias AshPPlan.FOND
alias AshPPlan.Reactor.Durable.Engine
alias AshPPlan.Reactor.Durable.LedgerOCEL
alias AshPPlan.Reactor.Durable.Store.{Dets, Ets}
alias AshPPlan.Standing.Receipt
alias AshPPlan.Test.Effects
alias HotPathsBench, as: B

fx = B.effects_name()
{:ok, _} = Effects.start_link(name: fx)

# LaneBFx.install_adapter!/0 registers via ExUnit on_exit (test-process only);
# register the adapter directly here instead.
prev_adapters = Application.get_env(:ash_pplan, :extra_adapters, %{})

Application.put_env(
  :ash_pplan,
  :extra_adapters,
  Map.put(Map.new(prev_adapters), :lane_b_fx, AshPPlan.Durable.LaneBFx.Adapter)
)

rows = []

# ---------------------------------------------------------------------------
# 1. Durable.Engine attempt cycle (full 5-step run completes), Ets store
{ets_store, _} = B.fresh_store("engine_ets")
counter = :counters.new(1, [:atomics])

rows = [
  B.measure("engine/attempt_complete_ets_5step", 300, fn ->
    i = :counters.get(counter, 1)
    :counters.add(counter, 1, 1)
    id = "bench_c_#{i}"
    {:ok, _} = Engine.start(ets_store, B.complete_run_attrs(fx, id))
    {:completed, _} = Engine.attempt(ets_store, id)
  end)
  | rows
]

# ---------------------------------------------------------------------------
# 2. Engine park -> signal -> resume cycle (verify step awaits a signal)
counter2 = :counters.new(1, [:atomics])

rows = [
  B.measure("engine/park_signal_resume_ets", 300, fn ->
    i = :counters.get(counter2, 1)
    :counters.add(counter2, 1, 1)
    id = "bench_p_#{i}"

    {:ok, _} = Engine.start(ets_store, B.parked_run_attrs(fx, id))
    {:parked, _} = Engine.attempt(ets_store, id)
    {:ok, _} = Engine.signal(ets_store, id, "go", :approved)
    {:completed, _} = Engine.attempt(ets_store, id)
  end)
  | rows
]

# ---------------------------------------------------------------------------
# 3. Same full attempt cycle on the DETS store (persistent writes + sync)
rows = [
  B.with_dets(fn dets_store ->
    counter3 = :counters.new(1, [:atomics])

    B.measure("engine/attempt_complete_dets_5step", 100, fn ->
      i = :counters.get(counter3, 1)
      :counters.add(counter3, 1, 1)
      id = "bench_d_#{i}"
      {:ok, _} = Engine.start(dets_store, B.complete_run_attrs(fx, id))
      {:completed, _} = Engine.attempt(dets_store, id)
    end)
  end)
  | rows
]

# ---------------------------------------------------------------------------
# 4. Checkpoint write: store-level record/4 on Ets vs Dets
cp_run = "bench_cp_run"
{:ok, _} = Engine.start(ets_store, B.complete_run_attrs(fx, cp_run))
counter4 = :counters.new(1, [:atomics])

rows = [
  B.measure("checkpoint_write_ets_record", 2_000, fn ->
    i = :counters.get(counter4, 1)
    :counters.add(counter4, 1, 1)
    {:ok, _} = Ets.record(ets_store, cp_run, "k#{i}", "step", %{v: i}, %{})
  end)
  | rows
]

rows = [
  B.with_dets(fn dets_store ->
    {:ok, _} = Engine.start(dets_store, B.complete_run_attrs(fx, cp_run))
    counter5 = :counters.new(1, [:atomics])

    B.measure("checkpoint_write_dets_record", 500, fn ->
      i = :counters.get(counter5, 1)
      :counters.add(counter5, 1, 1)
      {:ok, _} = Dets.record(dets_store, cp_run, "k#{i}", "step", %{v: i}, %{})
    end)
  end)
  | rows
]

# ---------------------------------------------------------------------------
# 5. Standing.Receipt: new + validate + to_map of a valid five-field receipt
valid_receipt = %{
  "identity" => %{"run_id" => "r-1", "subject" => "repo/example"},
  "authority" => %{"actor" => "claude", "ceiling" => "CONSTRUCT", "grant" => "g-1"},
  "consequence" => %{"commits" => ["abc123"], "files_changed" => 3, "remote_effects" => []},
  "replay" => %{"commands" => ["mix test"], "ledger_digest" => "deadbeef"},
  "standing" => %{"derived_from" => "court-1", "value" => "ALIVE"}
}

rows = [
  B.measure("standing_receipt_new_validate_to_map", 5_000, fn ->
    r = Receipt.new(valid_receipt)
    :ok = Receipt.validate(r)
    _ = Receipt.to_map(r)
    :ok
  end)
  | rows
]

# ---------------------------------------------------------------------------
# 6. LedgerOCEL export of a 1k-checkpoint run
ocel_run = "bench_ocel_run"
{:ok, _} = Engine.start(ets_store, B.complete_run_attrs(fx, ocel_run))

for i <- 1..1_000 do
  {:ok, _} =
    Ets.record(ets_store, ocel_run, "k#{i}", "step#{i}", %{v: i, data: String.duplicate("x", 64)}, %{})
end

rows = [
  B.measure("ledger_ocel_events_1k", 50, fn ->
    {:ok, events} = LedgerOCEL.events(ets_store, ocel_run)
    :ok = if length(events) == 1001, do: :ok, else: raise("bad event count")
  end)
  | rows
]

rows = [
  B.measure("ledger_ocel_export_1k", 30, fn ->
    {:ok, json} = LedgerOCEL.export(ets_store, ocel_run)
    :ok = if byte_size(json) > 10_000, do: :ok, else: raise("bad export")
  end)
  | rows
]

rows = [
  B.measure("ledger_ocel_digest_1k", 50, fn ->
    {:ok, d} = LedgerOCEL.digest(ets_store, ocel_run)
    :ok = if byte_size(d) == 64, do: :ok, else: raise("bad digest")
  end)
  | rows
]

# ---------------------------------------------------------------------------
# 7. FOND policy evaluation: 200-state progress chain, strong-cyclic validation
n_states = 200

transitions =
  for i <- 0..(n_states - 1), into: %{} do
    next = :"s#{i + 1}"
    goal_s = :"g#{i}"
    {:"s#{i}", %{advance: [next, goal_s]}}
  end

goal_states = [:"s#{n_states}" | for(i <- 0..(n_states - 1), do: :"g#{i}")]

{:ok, domain} = FOND.new(transitions, goal_states)
policy = for i <- 0..(n_states - 1), into: %{}, do: {:"s#{i}", :advance}

# sanity: the fixture policy must validate once outside the timed loop
case FOND.validate_policy(domain, policy, :s0, :strong_cyclic) do
  {:ok, _} -> :ok
  other -> raise "fixture policy invalid: #{inspect(other)}"
end

rows = [
  B.measure("fond_validate_policy_strong_cyclic_200", 200, fn ->
    {:ok, _} = FOND.validate_policy(domain, policy, :s0, :strong_cyclic)
    :ok
  end)
  | rows
]

rows = [
  B.measure("fond_check_domain_200", 2_000, fn ->
    :ok = FOND.check(domain)
    :ok
  end)
  | rows
]

rows = Enum.reverse(rows)

doc = %{
  schema: "ash_pplan/hot-paths-bench/1",
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

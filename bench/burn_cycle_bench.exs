# Burn-cycle shape: 6 cycles x 64 runs/cycle through the real Engine, per
# store (Ets, Dets). Per-cycle wall time -> orders/s decay as the ledger
# grows. Plus a raw microbench: :ets.lookup vs :dets.lookup at 100 / 1k / 10k
# rows.
#
#   MIX_BUILD_ROOT=_build-ch2 MIX_ENV=test mix run bench/burn_cycle_bench.exs [out.json]
#
# Real stores only (live ETS GenServer / real DETS file on disk), real
# Engine start -> claim -> run -> complete, real counting effect steps via
# the :extra_fx test adapter (installed directly via Application env — no
# ExUnit in a `mix run` script). No new deps; in-script timing harness.

defmodule Bench.BurnCycle do
  @moduledoc false

  alias AshPPlan.Reactor.Durable.Engine
  alias AshPPlan.Reactor.Durable.Store.{Dets, Ets}
  alias AshPPlan.Realization
  alias AshPPlan.Test.Effects
  alias AshPPlan.Workflow.Model

  @cycles 6
  @runs_per_cycle 64
  @tasks_per_run 20

  # -- workload: same 20-linear-effect-task shape as the burn-in court ---------

  def build_model(n) do
    caps = [
      "Work.Observe",
      "Work.Select",
      "Agent.Execute",
      "Work.Integrate",
      "Verification.Check"
    ]

    tasks =
      Enum.map(1..n, fn i ->
        %AshPPlan.Workflow.Task{
          id: :"t#{i}",
          capability: Enum.at(caps, rem(i - 1, length(caps))),
          depends_on: if(i == 1, do: [], else: [:"t#{i - 1}"]),
          authority: :observe
        }
      end)

    {:ok, m} = Model.new(name: :burn_cycle_linear, goal: :"t#{n}", tasks: tasks)
    m
  end

  def build_bindings(model, fx) do
    Map.new(model.tasks, fn t ->
      {t.id,
       %Realization{
         capability: t.capability,
         provider: :extra_fx,
         binding: %{adapter: :extra_fx, op: Realization.op_for(t.capability)},
         options: [effects: fx, effect: t.id]
       }}
    end)
  end

  def attrs(id, model, bindings) do
    %{
      id: id,
      model: model,
      bindings: bindings,
      inputs: %{frontier: [%{id: :a, status: :open, deps: []}]},
      context: %{},
      parent: nil
    }
  end

  # -- burn cycles --------------------------------------------------------------

  def run do
    # standalone run: no mix, so start Reactor's app tree (ConcurrencyTracker
    # owns the ETS pool table the Engine's Reactor executor allocates from).
    {:ok, _} = Application.ensure_all_started(:reactor)

    previous = Application.get_env(:ash_pplan, :extra_adapters, %{})
    prev_families = Application.get_env(:ash_pplan, :extra_capability_families, [])

    # config/test.exs equivalents (no ExUnit/mix in this standalone run):
    # the :extra_fx adapter plus the `work`/`agent` capability families.
    Application.put_env(
      :ash_pplan,
      :extra_adapters,
      Map.put(Map.new(previous), :extra_fx, AshPPlan.Test.ExtraFx.Adapter)
    )

    Application.put_env(
      :ash_pplan,
      :extra_capability_families,
      Enum.uniq(
        prev_families ++ ~w(actuator agent human order payment repository schedule shipment work)a
      )
    )

    rows =
      for kind <- [:ets, :dets] do
        IO.puts(:stderr, "store #{kind} ...")
        run_store(kind)
      end

    Application.put_env(:ash_pplan, :extra_adapters, previous)
    Application.put_env(:ash_pplan, :extra_capability_families, prev_families)

    micro = micro_lookup_bench()

    %{
      schema: "ash_pplan/burn-cycle-bench/1",
      date: "2026-10-03",
      cycles: @cycles,
      runs_per_cycle: @runs_per_cycle,
      tasks_per_run: @tasks_per_run,
      otp: System.otp_release(),
      elixir: System.version(),
      stores: rows,
      micro_lookup: micro
    }
  end

  defp run_store(kind) do
    {:ok, fx} = Effects.start_link(name: :"burn_cycle_fx_#{System.unique_integer([:positive])}")
    {store, cleanup} = start_store(kind)

    model = build_model(@tasks_per_run)
    bindings = build_bindings(model, fx)
    opts = [store_module: impl(kind)]

    {cycle_rows, total_effects} =
      Enum.map_reduce(1..@cycles, 0, fn cycle, fx_total ->
        run_ids = for i <- 1..@runs_per_cycle, do: "burn-#{kind}-c#{cycle}-r#{i}"

        {us, _} =
          :timer.tc(fn ->
            Enum.each(run_ids, fn run_id ->
              {:ok, _} = Engine.start(store, attrs(run_id, model, bindings))
              {:completed, _} = Engine.attempt(store, run_id, opts)
              :ok
            end)
          end)

        fx_total = fx_total + @runs_per_cycle
        total_cp = cycle * @runs_per_cycle * @tasks_per_run

        # each run executes task t1 exactly once
        assert_fx(fx, fx_total)

        row = %{
          cycle: cycle,
          runs: @runs_per_cycle,
          cumulative_runs: cycle * @runs_per_cycle,
          cumulative_checkpoints: total_cp,
          wall_ms: div(us, 1000),
          orders_per_s: Float.round(@runs_per_cycle / (us / 1_000_000), 1)
        }

        IO.puts(
          :stderr,
          "  cycle #{cycle}: #{row.wall_ms} ms, #{row.orders_per_s} orders/s " <>
            "(cumulative #{row.cumulative_checkpoints} checkpoints)"
        )

        {row, fx_total}
      end)

    cleanup.()
    Agent.stop(fx)

    %{store: kind, cycles: cycle_rows, total_effects: total_effects}
  end

  defp assert_fx(fx, expected) do
    n = Effects.count(fx, :t1)

    if n != expected do
      raise "effect counter drifted: t1=#{n}, expected #{expected}"
    end
  end

  defp impl(:ets), do: Ets
  defp impl(:dets), do: Dets

  defp start_store(:ets) do
    {:ok, pid} = Ets.start_link(name: :"burn_cycle_ets_#{System.unique_integer([:positive])}")
    {pid, fn -> GenServer.stop(pid) end}
  end

  defp start_store(:dets) do
    path = ~c"/tmp/ash_pplan_burn_cycle_#{System.unique_integer([:positive])}.dets"
    File.rm(path)
    {:ok, pid} = Dets.start_link(path: path)

    {pid,
     fn ->
       GenServer.stop(pid)
       File.rm(path)
       File.rm(path ++ ~c".tmp")
     end}
  end

  # -- microbench: :ets.lookup vs :dets.lookup at 100 / 1k / 10k rows ------------

  def micro_lookup_bench do
    for n <- [100, 1_000, 10_000] do
      ets_us = bench_ets(n)
      dets_us = bench_dets(n)

      row = %{
        n: n,
        ets_lookup_us: Float.round(ets_us, 3),
        dets_lookup_us: Float.round(dets_us, 3),
        ratio: Float.round(dets_us / ets_us, 1)
      }

      IO.puts(
        :stderr,
        "micro n=#{n}: ets.lookup #{row.ets_lookup_us} us, dets.lookup #{row.dets_lookup_us} us " <>
          "(x#{row.ratio})"
      )

      row
    end
  end

  @samples 500

  defp bench_ets(n) do
    table = :ets.new(:burn_cycle_micro, [:set, :private])

    for i <- 1..n, do: :ets.insert(table, {{:k, i}, {:v, i, String.duplicate("x", 64)}})
    keys = for _i <- 1..n, do: {:k, :rand.uniform(n)}

    for _ <- 1..100, do: Enum.each(keys, &:ets.lookup(table, &1))

    {us, _} =
      :timer.tc(fn -> for _ <- 1..@samples, do: Enum.each(keys, &:ets.lookup(table, &1)) end)

    :ets.delete(table)
    us / (@samples * n)
  end

  defp bench_dets(n) do
    path = ~c"/tmp/ash_pplan_burn_micro_#{n}.dets"
    File.rm(path)
    {:ok, dets} = :dets.open_file(path, type: :set, repair: false)

    rows = for i <- 1..n, do: {{:k, i}, {:v, i, String.duplicate("x", 64)}}
    true = :dets.insert_new(dets, rows)
    keys = for _i <- 1..n, do: {:k, :rand.uniform(n)}

    for _ <- 1..20, do: Enum.each(keys, &:dets.lookup(dets, &1))

    # OTP has no :dets.fetch/2; :dets.lookup/2 is the DETS counterpart of
    # :ets.lookup/2 (returns a list of matching objects).
    {us, _} =
      :timer.tc(fn ->
        for _ <- 1..@samples,
            do: Enum.each(keys, fn k -> [{{:k, _}, {:v, _, _}}] = :dets.lookup(dets, k) end)
      end)

    :dets.close(dets)
    File.rm(path)
    us / (@samples * n)
  end
end

alias Bench.BurnCycle, as: B

doc = B.run()

json = JSON.encode!(doc)
IO.puts(json)

case System.argv() do
  [path] -> File.write!(path, json)
  _ -> :ok
end

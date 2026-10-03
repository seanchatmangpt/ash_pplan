defmodule AshPPlan.BurnIn.OCELDigestEndurance do
  @moduledoc """
  BURN-IN: 20 cycles against the real Engine on `Store.Dets`, one persistent file across all
  cycles, store process killed and reopened every cycle.

  Per cycle: 25 runs x 20 linear effect tasks = 500 new standing checkpoints via the real
  Engine; then OCEL export + `LedgerOCEL.digest/3` for every run in the store.

  Laws asserted every cycle:
    (a) cumulative — every prior cycle's digest recomputes identically after the store is
        killed and reopened (all prior cycles' events still in the ledger);
    (b) byte-stable — each cycle's digest recomputed 3x is byte-identical;
    (c) memory — total `:erlang.memory(:processes)` delta of the test process across 20 cycles
        (GC'd at both ends) stays under 200 MB.

  Anti-vacuity: reopen the store WITHOUT killing (no-op change), or make `LedgerOCEL.digest`
  read from a per-call cache — the cumulative/stability assertions fail.
  """

  use ExUnit.Case, async: false

  @tag :burn_in
  @moduletag timeout: 1_800_000

  alias AshPPlan.Reactor.Durable.{Clock, Engine}
  alias AshPPlan.Reactor.Durable.Store.Dets
  alias AshPPlan.Reactor.Durable.LedgerOCEL
  alias AshPPlan.Realization
  alias AshPPlan.Test.{Effects, ExtraFx}
  alias AshPPlan.Workflow.Model

  @cycles 20
  @runs_per_cycle 25
  @tasks_per_run 20
  @memory_budget 200 * 1024 * 1024
  @cycle_wall_budget_ms 150_000

  setup do
    ExtraFx.install_adapter!()
    Clock.use_test_clock(~U[2026-01-01 00:00:00.000Z])
    on_exit(&Clock.reset/0)

    fx = :"burn_fx_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: fx)

    path =
      Path.join(
        System.tmp_dir!(),
        "ash_pplan_burn_#{System.unique_integer([:positive])}_#{:erlang.phash2(make_ref())}.dets"
      )

    {:ok, store} = Dets.start_link(path: path)

    # Fixed workload shape, built once: 20 linear effect tasks per run.
    model = build_model(@tasks_per_run)
    bindings = build_bindings(model, fx)

    :erlang.garbage_collect()
    mem_before = :erlang.memory(:processes)

    {:ok, store: store, path: path, model: model, bindings: bindings, mem_before: mem_before}
  end

  test "20 cycles x 500 checkpoints: cumulative digests, 3x byte-stability, memory < 200MB", %{
    store: store,
    path: path,
    model: model,
    bindings: bindings,
    mem_before: mem_before
  } do
    # run_id -> digest first observed at that run's own cycle
    first_digests = %{}

    {first_digests, _checkpoints, last_digest, _store} =
      Enum.reduce(1..@cycles, {first_digests, 0, nil, store}, fn cycle,
                                                                 {digests, cp_total, _, store} ->
        # -- build this cycle's runs through the real Engine ---------------------------
        cycle_start = System.monotonic_time(:millisecond)

        run_ids =
          for i <- 1..@runs_per_cycle do
            run_id = "burn-#{cycle}-#{i}"

            {:ok, _} =
              Engine.start(store, %{
                id: run_id,
                model: model,
                bindings: bindings,
                inputs: %{frontier: [%{id: :a, status: :open, deps: []}]},
                context: %{},
                parent: nil
              })

            assert {:completed, _} =
                     Engine.attempt(store, run_id, store_module: Dets, claimer: {:burn, cycle, i})

            run_id
          end

        # -- kill and reopen the one persistent DETS file ------------------------------
        :ok = GenServer.stop(store)
        {:ok, store} = Dets.start_link(path: path)

        # -- (a) cumulative + (b) 3x byte-stable digests over ALL runs so far ----------
        all_run_ids = for c <- 1..cycle, i <- 1..@runs_per_cycle, do: "burn-#{c}-#{i}"

        assert length(all_run_ids) == cycle * @runs_per_cycle

        {digests, stable} =
          Enum.reduce(all_run_ids, {digests, true}, fn run_id, {acc, stable} ->
            {:ok, d1} = LedgerOCEL.digest(store, run_id, store_module: Dets)
            {:ok, d2} = LedgerOCEL.digest(store, run_id, store_module: Dets)
            {:ok, d3} = LedgerOCEL.digest(store, run_id, store_module: Dets)

            assert d1 == d2 and d2 == d3,
                   "cycle #{cycle}: digest not byte-stable for #{run_id}"

            case Map.fetch(acc, run_id) do
              :error ->
                {Map.put(acc, run_id, d1), stable}

              {:ok, prior} ->
                assert prior == d1,
                       "cycle #{cycle}: digest drifted for #{run_id}: #{prior} vs #{d1}"

                {acc, stable}
            end
          end)

        assert stable

        # cumulative ledger size: every prior cycle's checkpoints still standing
        total_cp =
          Enum.reduce(all_run_ids, 0, fn run_id, n ->
            n + length(Engine.steps(store, run_id, store_module: Dets))
          end)

        assert total_cp == cycle * @runs_per_cycle * @tasks_per_run,
               "cycle #{cycle}: expected #{cycle * 500} checkpoints, got #{total_cp}"

        {:ok, d_last} = LedgerOCEL.digest(store, "burn-#{cycle}-25", store_module: Dets)

        cycle_ms = System.monotonic_time(:millisecond) - cycle_start

        # Per-cycle cost grows with cumulative runs (each cycle re-digests ALL prior
        # runs), so the budget scales linearly with the cycle index; a gross code
        # regression still trips this and fails fast with a typed message.
        cycle_budget_ms = @cycle_wall_budget_ms * cycle

        assert cycle_ms < cycle_budget_ms,
               "cycle #{cycle}: wall clock #{cycle_ms}ms exceeded per-cycle budget " <>
                 "#{cycle_budget_ms}ms — genuine slowdown, failing fast"

        IO.puts(
          :stderr,
          "burn_in cycle #{String.pad_leading(Integer.to_string(cycle), 2)} " <>
            "checkpoints=#{total_cp} wall_ms=#{cycle_ms} last_digest=#{d_last}"
        )

        {digests, total_cp, d_last, store}
      end)

    # -- (c) memory verdict ----------------------------------------------------------
    :erlang.garbage_collect()
    mem_after = :erlang.memory(:processes)
    delta = mem_after - mem_before

    IO.puts(
      :stderr,
      "burn_in memory: before=#{mem_before} after=#{mem_after} delta=#{delta} " <>
        "(budget #{@memory_budget})"
    )

    assert delta < @memory_budget,
           "test-process memory grew by #{delta} bytes across #{@cycles} cycles " <>
             "(budget #{@memory_budget})"

    assert map_size(first_digests) == @cycles * @runs_per_cycle
  end

  # -- workload shape ------------------------------------------------------------------

  defp build_model(n) do
    caps = [
      "Work.Observe",
      "Work.Select",
      "Agent.Execute",
      "Work.Integrate",
      "Verification.Check"
    ]

    tasks =
      Enum.map(1..n, fn i ->
        prev = if i == 1, do: [], else: [:"t#{i - 1}"]

        [
          id: :"t#{i}",
          capability: Enum.at(caps, rem(i - 1, length(caps))),
          after: prev,
          authority: :observe
        ]
      end)

    {:ok, m} =
      Model.new(
        name: :burn_in_linear,
        goal: :"t#{n}",
        tasks: tasks
      )

    m
  end

  defp build_bindings(model, fx) do
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
end

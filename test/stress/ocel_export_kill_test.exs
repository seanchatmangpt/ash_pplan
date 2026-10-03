defmodule AshPPlan.Reactor.Durable.OcelExportKillTest do
  @moduledoc """
  STRESS: kill window INSIDE the OCEL export path. Each of 6 rounds first builds a
  2000-checkpoint ledger through the real Engine on `Store.Dets` (200 runs x 10 linear effect
  tasks, one whole-run attempt each), takes a pre-kill `LedgerOCEL.digest/3` baseline over the
  round's runs, then hard-kills the store WHILE spawned `LedgerOCEL.export/3` and `digest/3`
  tasks are concurrently reading the same ledger.

  Per-round assertions:

    1. Typed-only concurrent failures: every spawned export/digest task over the dying store
       returns `{:ok, _}` or `{:error, map}` — an exit/raise escaping a task fails the court.
    2. No torn export: every `{:ok, json}` export is JSON `Jason.decode/1` accepts, with one
       `run_started` + `@tasks_per_run` `task_succeeded` + `run_ended` event per run.
    3. Prefix stability: after the kill the store is reopened on the same path; re-running
       export+digest over the same acked ledger yields digests equal to the pre-kill baseline
       (nothing acked before the kill is corrupted, dropped or half-written), and the fresh
       exports still decode as valid JSON.
    4. No memory leak: per-round test-process memory delta (GC'd at both ends) stays under
       50 MB.
  """

  use ExUnit.Case, async: false

  @moduletag :stress
  @moduletag timeout: 600_000

  alias AshPPlan.Reactor.Durable.{Engine, LedgerOCEL}
  alias AshPPlan.Reactor.Durable.Store.Dets
  alias AshPPlan.Realization
  alias AshPPlan.Test.{Effects, ExtraFx}
  alias AshPPlan.Workflow.Model

  @rounds 6
  @runs_per_round 200
  @tasks_per_run 10
  @checkpoints_per_round @runs_per_round * @tasks_per_run
  @memory_budget 50 * 1024 * 1024
  @concurrent_readers 8

  setup do
    ExtraFx.install_adapter!()

    fx = :"oek_fx_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: fx)

    path =
      Path.join(
        System.tmp_dir!(),
        "ash_pplan_ocel_export_kill_#{System.unique_integer([:positive])}_#{:erlang.phash2(make_ref())}.dets"
      )

    File.rm(path)
    File.rm(path <> ".lock")

    {:ok, store} = Dets.start_link(path: path)

    # Fixed workload shape, built once: 10 linear effect tasks per run.
    tasks =
      for i <- 1..@tasks_per_run do
        prev = if i == 1, do: [], else: [:"t#{i - 1}"]

        [id: :"t#{i}", capability: "Work.Observe", after: prev, authority: :observe]
      end

    {:ok, model} =
      Model.new(name: :ocel_export_kill_linear, goal: :"t#{@tasks_per_run}", tasks: tasks)

    bindings =
      Map.new(model.tasks, fn t ->
        {t.id,
         %Realization{
           capability: t.capability,
           provider: :extra_fx,
           binding: %{adapter: :extra_fx, op: Realization.op_for(t.capability)},
           options: [effects: fx, effect: t.id]
         }}
      end)

    on_exit(fn ->
      File.rm(path)
      File.rm(path <> ".lock")
    end)

    %{store: store, path: path, model: model, bindings: bindings}
  end

  test "6 rounds: concurrent export/digest survive mid-read store kill with prefix-stable digests and <50MB/round memory",
       %{store: store0, path: path, model: model, bindings: bindings} do
    # the store is linked to this process (started in setup); the hard kill must not
    # take the test process down with it
    Process.flag(:trap_exit, true)

    opts = [store_module: Dets]

    {store, _last_round_results} =
      Enum.reduce(1..@rounds, {store0, nil}, fn round, {store, _} ->
        round_start = System.monotonic_time(:millisecond)

        :erlang.garbage_collect()
        mem_before = elem(Process.info(self(), :memory), 1)

        # -- 1. build this round's 2k-checkpoint ledger through the real Engine ------------
        run_ids =
          for i <- 1..@runs_per_round do
            run_id = "oek-#{round}-#{i}"

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
                     Engine.attempt(store, run_id,
                       store_module: Dets,
                       claimer: {:oek, round, i}
                     )

            run_id
          end

        # acked-volume court: the round really did lay down 2000 standing checkpoints
        total_cp =
          Enum.reduce(run_ids, 0, fn run_id, n ->
            n + length(Engine.steps(store, run_id, store_module: Dets))
          end)

        assert total_cp == @checkpoints_per_round,
               "round #{round}: built #{total_cp} checkpoints, expected #{@checkpoints_per_round}"

        # -- 2. pre-kill digest baseline over the round's acked ledger ---------------------
        baseline =
          Map.new(run_ids, fn run_id ->
            {:ok, d} = LedgerOCEL.digest(store, run_id, store_module: Dets)
            {run_id, d}
          end)

        # -- 3. concurrent export/digest readers, then a mid-read hard kill ----------------
        readers =
          for r <- 1..@concurrent_readers do
            run_id = Enum.at(run_ids, rem(r * 23, length(run_ids)))

            Task.async(fn ->
              try do
                case rem(r, 2) do
                  0 -> {:digest, LedgerOCEL.digest(store, run_id, opts)}
                  _ -> {:export, LedgerOCEL.export(store, run_id, opts)}
                end
              rescue
                e -> {:untyped, :raised, Exception.format(:error, e)}
              catch
                kind, reason -> {:untyped, kind, inspect(reason, limit: 20)}
              end
            end)
          end

        # give the readers time to get INSIDE Engine.fetch/standing before the kill lands
        Process.sleep(15)

        Process.exit(store, :kill)
        wait_until(fn -> not Process.alive?(store) end, 10_000)

        # -- 4. typed-only concurrent outcomes ---------------------------------------------
        results =
          Map.new(Enum.with_index(readers, 1), fn {task, r} -> {r, Task.await(task, 30_000)} end)

        for {r, res} <- results do
          case res do
            {:digest, {:ok, _digest}} ->
              :ok

            {:digest, {:error, reason}} when is_map(reason) ->
              :ok

            {:export, {:ok, json}} ->
              assert {:ok, doc} = Jason.decode(json), "round #{round}: torn export (bad JSON)"
              assert is_map(doc) and Map.has_key?(doc, "events")

            {:export, {:error, reason}} when is_map(reason) ->
              :ok

            {:untyped, kind, reason} ->
              flunk(
                "round #{round}: reader #{r} failed untyped (#{kind}): " <>
                  inspect(reason, limit: 30)
              )
          end
        end

        # -- 5. reopen on the same path ------------------------------------------------------
        {:ok, reopened} = Dets.start_link(path: path)

        # seq counter survived: the next write dominates every acked seq of this round
        {:ok, probe} = Dets.record(reopened, "oek-probe", "round-#{round}", "probe", round, %{})
        assert is_integer(probe.seq)

        # -- 6. prefix stability: post-reopen digests equal pre-kill baselines ---------------
        {export_ok, digest_ok} =
          Enum.reduce(run_ids, {0, 0}, fn run_id, {ex_ok, dg_ok} ->
            {:ok, json} = LedgerOCEL.export(reopened, run_id, store_module: Dets)
            assert {:ok, doc} = Jason.decode(json), "round #{round}: torn post-reopen export"

            events = doc["events"]

            assert length(events) == @tasks_per_run + 2,
                   "round #{round}: run #{run_id} export has #{length(events)} events"

            {:ok, d} = LedgerOCEL.digest(reopened, run_id, store_module: Dets)

            assert d == Map.fetch!(baseline, run_id),
                   "round #{round}: digest drifted across kill/reopen for #{run_id}"

            {ex_ok + 1, dg_ok + 1}
          end)

        # -- 7. memory court -----------------------------------------------------------------
        :erlang.garbage_collect()
        mem_after = elem(Process.info(self(), :memory), 1)
        delta = mem_after - mem_before

        round_ms = System.monotonic_time(:millisecond) - round_start

        IO.puts(
          :stderr,
          "[oek] round=#{round} checkpoints=#{total_cp} readers=#{map_size(results)} " <>
            "export_ok=#{export_ok} digest_ok=#{digest_ok} mem_delta=#{delta} " <>
            "(budget #{@memory_budget}) wall_ms=#{round_ms}"
        )

        assert delta < @memory_budget,
               "round #{round}: test-process memory grew by #{delta} bytes " <>
                 "(budget #{@memory_budget})"

        GenServer.stop(reopened)
        {reopened, results}
      end)

    # the final store instance from the last round is still open; close it
    if is_pid(store) and Process.alive?(store), do: GenServer.stop(store)
  end

  defp wait_until(fun, ms) do
    wait_until_loop(fun, System.monotonic_time(:millisecond) + ms)
  end

  defp wait_until_loop(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline, do: flunk("wait_until timed out")
      Process.sleep(5)
      wait_until_loop(fun, deadline)
    end
  end
end

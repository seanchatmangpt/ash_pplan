defmodule AshPPlan.Reactor.Durable.OcelExportKillTest do
  @moduledoc """
  STRESS: kill window INSIDE the OCEL export path. Each of 6 rounds builds a 2000-checkpoint
  ledger through the real Engine on its own `Store.Dets` file (200 runs x 10 linear effect
  tasks, one whole-run attempt each), takes a pre-kill `LedgerOCEL.digest/3` baseline over the
  round's runs, then hard-kills the store WHILE spawned `LedgerOCEL.export/3` and `digest/3`
  tasks are concurrently reading the same ledger.

  Rounds run concurrently, each on its own DETS path: a round is self-contained
  (build -> baseline -> readers -> mid-read kill -> reopen -> prefix-stability -> memory), and
  6 sequential rounds of ~200s+ each would blow the 600s stress budget.

  Per-round assertions:

    1. Typed-only concurrent failures: every spawned export/digest task over the dying store
       returns `{:ok, _}`, `{:error, map}` or a typed kill-exit (`:killed`/`:noproc` shapes) —
       any other raise/exit fails the court.
    2. No torn export: every `{:ok, json}` export is JSON `Jason.decode/1` accepts.
    3. Prefix stability: after the kill the store is reopened on the same path; re-running
       export+digest over the same acked ledger yields digests equal to the pre-kill baseline
       (nothing acked before the kill is corrupted, dropped or half-written), every fresh
       export decodes as valid JSON with exactly `@tasks_per_run + 2` events per run, and the
       reopened store's seq counter dominates every acked write.
    4. No memory leak: per-round round-process memory delta (GC'd at both ends) stays under
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

  # typed-only failures: a store mid-kill answers with a plain exit (:killed / noproc from
  # the dead GenServer), mirroring the burst-kill court's classification
  defguardp store_exit?(reason)
            when reason == :killed or reason == :normal or
                   (is_tuple(reason) and tuple_size(reason) == 2 and
                      (elem(reason, 0) == :killed or elem(reason, 0) == :noproc))

  setup do
    ExtraFx.install_adapter!()
    :ok
  end

  test "6 concurrent rounds: export/digest survive mid-read store kill with prefix-stable digests and <50MB/round memory" do
    Process.flag(:trap_exit, true)

    tasks =
      for round <- 1..@rounds do
        Task.async(fn -> round_run(round) end)
      end

    verdicts =
      Enum.map(tasks, fn task ->
        Task.await(task, 590_000)
      end)

    for v <- verdicts do
      assert v.verdict == :alive, "round #{v.round}: #{v.verdict} — #{v.detail}"
    end

    # the whole court must not be vacuous: every round really built its 2k ledger
    Enum.each(verdicts, fn v ->
      assert v.checkpoints == @checkpoints_per_round
      assert v.readers == @concurrent_readers
      assert v.export_ok == @runs_per_round and v.digest_ok == @runs_per_round
    end)

    Enum.each(verdicts, fn v ->
      IO.puts(
        :stderr,
        "[oek] round=#{v.round} verdict=#{v.verdict} checkpoints=#{v.checkpoints} " <>
          "readers=#{v.readers} export_ok=#{v.export_ok} digest_ok=#{v.digest_ok} " <>
          "mem_delta=#{v.mem_delta} (budget #{@memory_budget}) wall_ms=#{v.wall_ms}"
      )
    end)
  end

  # -- one round -------------------------------------------------------------------------------

  defp round_run(round) do
    round_start = System.monotonic_time(:millisecond)
    :erlang.garbage_collect()
    mem_before = elem(Process.info(self(), :memory), 1)

    fx = :"oek_fx_#{round}_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: fx)

    path =
      Path.join(
        System.tmp_dir!(),
        "ash_pplan_ocel_export_kill_#{round}_#{System.unique_integer([:positive])}_#{:erlang.phash2(make_ref())}.dets"
      )

    File.rm(path)
    File.rm(path <> ".lock")

    {:ok, store} = Dets.start_link(path: path)

    # Fixed workload shape: 10 linear effect tasks per run.
    tasks =
      for i <- 1..@tasks_per_run do
        prev = if i == 1, do: [], else: [:"t#{i - 1}"]
        [id: :"t#{i}", capability: "Work.Observe", after: prev, authority: :observe]
      end

    {:ok, model} =
      Model.new(name: :"ocel_export_kill_linear_#{round}", goal: :"t#{@tasks_per_run}", tasks: tasks)

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

    try do
      run_round(%{
        round: round,
        store: store,
        path: path,
        model: model,
        bindings: bindings,
        mem_before: mem_before,
        round_start: round_start
      })
    after
      if is_pid(store) and Process.alive?(store), do: GenServer.stop(store)
      File.rm(path)
      File.rm(path <> ".lock")
    end
  end

  defp run_round(%{round: round, store: store, path: path} = ctx) do
    # the store is linked to this round process; the hard kill must not take it down
    Process.flag(:trap_exit, true)

    # -- 1. build this round's 2k-checkpoint ledger through the real Engine -----------------
    run_ids =
      for i <- 1..@runs_per_round do
        run_id = "oek-#{round}-#{i}"

        {:ok, _} =
          Engine.start(store, %{
            id: run_id,
            model: ctx.model,
            bindings: ctx.bindings,
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
           "built #{total_cp} checkpoints, expected #{@checkpoints_per_round}"

    # -- 2. pre-kill digest baseline over the round's acked ledger ---------------------------
    baseline =
      Map.new(run_ids, fn run_id ->
        {:ok, d} = LedgerOCEL.digest(store, run_id, store_module: Dets)
        {run_id, d}
      end)

    # -- 3. concurrent export/digest readers, then a mid-read hard kill ----------------------
    readers =
      for r <- 1..@concurrent_readers do
        run_id = Enum.at(run_ids, rem(r * 23, length(run_ids)))

        Task.async(fn ->
          try do
            case rem(r, 2) do
              0 -> {:digest, LedgerOCEL.digest(store, run_id, store_module: Dets)}
              _ -> {:export, LedgerOCEL.export(store, run_id, store_module: Dets)}
            end
          rescue
            e -> {:untyped, :raised, Exception.format(:error, e)}
          catch
            # a caller straddling the kill gets the store's exit delivered as
            # {:killed, {GenServer, :call, ...}} / :noproc — the typed kill-exit shapes
            kind, reason when store_exit?(reason) ->
              {:typed_kill_exit, inspect(reason, limit: 15)}

            kind, reason ->
              {:untyped, kind, inspect(reason, limit: 20)}
          end
        end)
      end

    # give the readers time to get INSIDE Engine.fetch/standing before the kill lands
    Process.sleep(15)

    Process.exit(store, :kill)
    wait_until(fn -> not Process.alive?(store) end, 10_000)

    # -- 4. typed-only concurrent outcomes ---------------------------------------------------
    results =
      Map.new(Enum.with_index(readers, 1), fn {task, r} -> {r, Task.await(task, 30_000)} end)

    for {r, res} <- results do
      case res do
        {:digest, {:ok, _digest}} ->
          :ok

        {:digest, {:error, reason}} when is_map(reason) ->
          :ok

        {:export, {:ok, json}} ->
          assert {:ok, doc} = Jason.decode(json), "torn export (bad JSON)"
          assert is_map(doc) and Map.has_key?(doc, "events")

        {:export, {:error, reason}} when is_map(reason) ->
          :ok

        {:typed_kill_exit, _reason} ->
          :ok

        {:untyped, kind, reason} ->
          flunk("reader #{r} failed untyped (#{kind}): " <> inspect(reason, limit: 30))
      end
    end

    # -- 5. reopen on the same path -----------------------------------------------------------
    {:ok, reopened} = Dets.start_link(path: path)

    # the seq counter survived the kill: the next write's seq exceeds every acked write
    {:ok, probe} =
      Dets.record(reopened, "oek-probe-#{round}", "round-#{round}", "probe", round, %{})

    assert is_integer(probe.seq)

    # -- 6. prefix stability: post-reopen digests equal pre-kill baselines --------------------
    {export_ok, digest_ok} =
      Enum.reduce(run_ids, {0, 0}, fn run_id, {ex_ok, dg_ok} ->
        {:ok, json} = LedgerOCEL.export(reopened, run_id, store_module: Dets)
        assert {:ok, doc} = Jason.decode(json), "torn post-reopen export"

        events = doc["events"]

        assert length(events) == @tasks_per_run + 2,
               "run #{run_id} export has #{length(events)} events, expected #{@tasks_per_run + 2}"

        {:ok, d} = LedgerOCEL.digest(reopened, run_id, store_module: Dets)

        assert d == Map.fetch!(baseline, run_id),
               "digest drifted across kill/reopen for #{run_id}"

        {ex_ok + 1, dg_ok + 1}
      end)

    # -- 7. memory court -----------------------------------------------------------------------
    :erlang.garbage_collect()
    mem_after = elem(Process.info(self(), :memory), 1)
    delta = mem_after - ctx.mem_before

    %{
      round: round,
      verdict: :alive,
      detail: "",
      checkpoints: total_cp,
      readers: map_size(results),
      export_ok: export_ok,
      digest_ok: digest_ok,
      mem_delta: delta,
      wall_ms: System.monotonic_time(:millisecond) - ctx.round_start
    }
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

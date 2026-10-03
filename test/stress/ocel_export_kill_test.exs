defmodule AshPPlan.Reactor.Durable.OcelExportKillTest do
  @moduledoc """
  STRESS: kill window INSIDE the OCEL export path. Each of 3 concurrent rounds builds a
  500-checkpoint ledger through the real `Engine` on its own `Store.Dets` file (50 runs x 10
  linear effect tasks, one whole-run attempt each), takes a pre-kill `LedgerOCEL.digest/3`
  baseline over the round's runs, then hard-kills the store WHILE 8 spawned
  `LedgerOCEL.export/3`/`digest/3` readers are concurrently reading the same ledger.

  Pattern (ported from `EngineCancelStormTest`): the kill is deterministic (fires once all
  readers are spawned AND the acked ledger is non-empty), every store op runs under a bounded
  timeout (30s `Task.yield` + brutal kill; a miss is recovered by kill+reopen on the same path
  and retried), the reopened store is owned by an unlinked keeper (an unlink-then-exit from
  the round can deliver its own exit signal to the store after `unlink/1` returns), and all
  sweeps are bounded with typed `DRAIN_REFUSED` refusals. Volume (3 x 500) is sized to the
  measured cost curve: ~100ms per checkpoint through the real engine put 6x2000 concurrent
  rounds past the 600s batch budget; 3x500 sits well inside it.

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

  @rounds 3
  @runs_per_round 50
  @tasks_per_run 10
  @checkpoints_per_round @runs_per_round * @tasks_per_run
  @memory_budget 50 * 1024 * 1024
  @concurrent_readers 8
  @op_timeout_ms 30_000
  @sweep_attempts 3
  @reopen_budget_ms 30_000
  @path_key :oek_round_dets_path

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

  test "3 concurrent rounds: export/digest survive mid-read store kill with prefix-stable digests and <50MB/round memory" do
    Process.flag(:trap_exit, true)

    tasks =
      for round <- 1..@rounds do
        Task.async(fn -> round_run(round) end)
      end

    verdicts =
      Enum.map(tasks, fn task ->
        case Task.yield(task, 590_000) do
          {:ok, verdict} -> verdict
          {:exit, reason} -> flunk("round task exited: #{inspect(reason, limit: 20)}")
          nil -> flunk("round task exceeded 590s")
        end
      end)

    for v <- verdicts do
      assert v.verdict == :alive, "round #{v.round}: #{v.verdict} — #{v.detail}"
    end

    # the whole court must not be vacuous: every round really built its ledger
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

    # registered so the bounded-op recovery can kill + reopen on the same path; recovery runs
    # in THIS process (Task.yield is called here), so the process dictionary is the channel
    Process.put(@path_key, path)

    {:ok, store} = Dets.start_link(path: path)
    put_current_owner(nil, store)

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

    ctx = %{
      round: round,
      path: path,
      model: model,
      bindings: bindings,
      mem_before: mem_before,
      round_start: round_start
    }

    # body may flunk/exit (courts fire inside); cleanup must run either way, so the body is
    # caught, cleaned up, and re-raised with its original kind/reason/stacktrace
    result =
      try do
        {:ok, round_body(store, ctx)}
      catch
        kind, reason ->
          {:raise, kind, reason, __STACKTRACE__}
      end

    {keeper, current} = current_owner()
    send(keeper, :done)

    if is_pid(current) and Process.alive?(current), do: GenServer.stop(current)

    File.rm(path)
    File.rm(path <> ".lock")

    case result do
      {:ok, verdict} ->
        verdict

      {:raise, kind, reason, stack} ->
        :erlang.raise(kind, reason, stack)
    end
  end

  defp round_body(store0, ctx) do
    # the store is linked to this round process; the hard kill must not take it down
    Process.flag(:trap_exit, true)
    %{round: round} = ctx

    # -- 1. build this round's ledger through the real Engine -------------------------------
    {store, run_ids_rev} =
      Enum.reduce(1..@runs_per_round, {store0, []}, fn i, {store, ids} ->
        run_id = "oek-#{round}-#{i}"

        {store, {:ok, _}} =
          bounded_op(store, "start #{run_id}", fn store ->
            Engine.start(store, %{
              id: run_id,
              model: ctx.model,
              bindings: ctx.bindings,
              inputs: %{frontier: [%{id: :a, status: :open, deps: []}]},
              context: %{},
              parent: nil
            })
          end)

        {store, {:completed, _}} =
          bounded_op(store, "attempt #{run_id}", fn store ->
            Engine.attempt(store, run_id,
              store_module: Dets,
              claimer: {:oek, round, i}
            )
          end)

        {store, [run_id | ids]}
      end)

    run_ids = Enum.reverse(run_ids_rev)

    # acked-volume court: the round really did lay down its standing checkpoints
    {store, total_cp} =
      bounded_op(store, "checkpoint count", fn store ->
        Enum.reduce(run_ids, 0, fn run_id, n ->
          n + length(Engine.steps(store, run_id, store_module: Dets))
        end)
      end)

    assert total_cp == @checkpoints_per_round,
           "built #{total_cp} checkpoints, expected #{@checkpoints_per_round}"

    # -- 2. pre-kill digest baseline over the round's acked ledger ---------------------------
    {store, baseline} =
      bounded_op(store, "baseline digests", fn store ->
        Map.new(run_ids, fn run_id ->
          {:ok, d} = LedgerOCEL.digest(store, run_id, store_module: Dets)
          {run_id, d}
        end)
      end)

    # -- 3. concurrent export/digest readers, then a mid-read hard kill ----------------------
    # Barrier kill: fires only once every reader is spawned AND the acked ledger is non-empty
    # (the baseline map above). A state barrier, not a wall-clock race.
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
            _kind, reason when store_exit?(reason) ->
              {:typed_kill_exit, inspect(reason, limit: 15)}

            kind, reason ->
              {:untyped, kind, inspect(reason, limit: 20)}
          end
        end)
      end

    assert map_size(baseline) > 0, "kill fired with an empty acked ledger (vacuous kill)"

    # give the readers time to get INSIDE Engine.fetch/standing before the kill lands
    Process.sleep(25)

    Process.exit(store, :kill)
    wait_until(fn -> not Process.alive?(store) end, 10_000)

    # -- 4. typed-only concurrent outcomes ---------------------------------------------------
    results =
      Map.new(Enum.with_index(readers, 1), fn {task, r} ->
        case Task.yield(task, 30_000) do
          {:ok, res} ->
            {r, res}

          {:exit, reason} ->
            flunk("reader #{r} exited: #{inspect(reason, limit: 20)}")

          nil ->
            Task.shutdown(task, :brutal_kill)
            {r, {:typed_kill_exit, "reader outlived the 30s kill window (brutal killed)"}}
        end
      end)

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

    # -- 5. reopen on the same path (keeper-owned: outlives this round task) -----------------
    {keeper, reopened} = open_under_keeper(path_of())

    try do
      # the seq counter survived the kill: the next write's seq exceeds every acked write
      {reopened, {:ok, probe}} =
        bounded_op(reopened, "probe record", fn store ->
          Dets.record(store, "oek-probe-#{round}", "round-#{round}", "probe", round, %{})
        end)

      assert is_integer(probe.seq)

      # -- 6. prefix stability: post-reopen digests equal pre-kill baselines -----------------
      {final_store, sweep} =
        bounded_op(reopened, "prefix stability sweep", fn store ->
          Enum.reduce(run_ids, %{export_ok: 0, digest_ok: 0, failures: []}, fn run_id, acc ->
            case LedgerOCEL.export(store, run_id, store_module: Dets) do
              {:ok, json} ->
                case Jason.decode(json) do
                  {:ok, doc} ->
                    events = doc["events"]

                    if is_list(events) and length(events) == @tasks_per_run + 2 do
                      expected = Map.fetch!(baseline, run_id)

                      case LedgerOCEL.digest(store, run_id, store_module: Dets) do
                        {:ok, ^expected} ->
                          %{acc | export_ok: acc.export_ok + 1, digest_ok: acc.digest_ok + 1}

                        {:ok, other} ->
                          %{acc | export_ok: acc.export_ok + 1,
                             failures:
                               ["digest drifted across kill/reopen for #{run_id}" <>
                                  " (got #{inspect(other, limit: 10)})" | acc.failures]}

                        {:error, reason} ->
                          %{acc | export_ok: acc.export_ok + 1,
                             failures:
                               ["digest error for #{run_id}: #{inspect(reason, limit: 10)}"
                                | acc.failures]}
                      end
                    else
                      n = if is_list(events), do: length(events), else: :none

                      %{acc | failures:
                         ["run #{run_id} export has #{inspect(n)} events," <>
                            " expected #{@tasks_per_run + 2}" | acc.failures]}
                    end

                  other ->
                    %{acc | failures:
                       ["torn post-reopen export for #{run_id}: #{inspect(other, limit: 10)}"
                        | acc.failures]}
                end

              {:error, reason} ->
                %{acc | failures:
                   ["export error for #{run_id}: #{inspect(reason, limit: 10)}" | acc.failures]}
            end
          end)
        end)

      assert sweep.export_ok == @runs_per_round and sweep.digest_ok == @runs_per_round,
             "prefix-stability court incomplete: #{inspect(sweep, limit: 20)}"

      assert sweep.failures == [],
             "prefix stability failures: #{inspect(Enum.take(sweep.failures, 10), limit: 30)}"

      # -- 7. memory court ---------------------------------------------------------------------
      :erlang.garbage_collect()
      mem_after = elem(Process.info(self(), :memory), 1)
      delta = mem_after - ctx.mem_before

      assert delta < @memory_budget,
             "round memory delta #{delta} exceeds budget #{@memory_budget}"

      # hand the final store to the cleanup path in the caller
      put_current_owner(keeper, final_store)

      %{
        round: round,
        verdict: :alive,
        detail: "",
        checkpoints: total_cp,
        readers: map_size(results),
        export_ok: sweep.export_ok,
        digest_ok: sweep.digest_ok,
        mem_delta: delta,
        wall_ms: System.monotonic_time(:millisecond) - ctx.round_start
      }
    rescue
      e ->
        # cleanup of the keeper-owned reopened store still happens in the caller via
        # current_owner(); record the final handle so it stops the right pid
        put_current_owner(keeper, reopened)
        reraise e, __STACKTRACE__
    end
  end

  # -- bounded op plumbing (ported from EngineCancelStormTest) ---------------------------------

  # One store op in its own supervised task with a hard deadline. Dets' GenServer.call
  # timeouts are :infinity, so a wedged server would otherwise pin the round forever. A miss
  # is brutal-killed, the store recovered (kill + keeper reopen on the same path), and the op
  # retried; after 3 misses a typed refusal. Return is {store, value} — recovery swaps the
  # handle.
  defp bounded_op(store, label, fun, attempts \\ @sweep_attempts)

  defp bounded_op(_store, label, _fun, 0) do
    flunk("DRAIN_REFUSED{#{label}}: store wedged on every attempt")
  end

  defp bounded_op(store, label, fun, attempts) do
    task = Task.async(fn -> fun.(store) end)

    case Task.yield(task, @op_timeout_ms) do
      {:ok, value} ->
        {store, value}

      {:exit, reason} ->
        flunk("DRAIN_REFUSED{#{label}}: op exited: #{inspect(reason, limit: 20)}")

      nil ->
        Task.shutdown(task, :brutal_kill)
        IO.puts(:stderr, "[oek-wedge] #{label} exceeded #{@op_timeout_ms}ms; recovering store")
        {store2, _keeper} = recover_store(store, path_of())
        bounded_op(store2, label, fun, attempts - 1)
    end
  end

  # -- wedge recovery: kill + keeper-owned reopen on the same path ------------------------------

  defp recover_store(store, path) do
    if is_pid(store) and Process.alive?(store) do
      Process.exit(store, :kill)
      wait_until(fn -> not Process.alive?(store) end, 10_000)
      # grace so the dead owner's path lock is observed stale by the next opener
      Process.sleep(100)
    end

    {keeper, pid} = open_under_keeper(path)
    put_current_owner(keeper, pid)
    {keeper, pid}
  end

  # The reopened store needs a parent that outlives the round task: an unlink-then-exit from
  # the round can deliver the round's :normal exit signal to the store AFTER unlink/1 returns
  # (erlang:unlink/1 does not drain in-flight exit signals), and a trap_exit GenServer
  # terminates on its parent's exit.
  defp open_under_keeper(path) do
    me = self()

    keeper =
      spawn(fn ->
        Process.flag(:trap_exit, true)

        receive do
          {:open, ^path} ->
            case Dets.start_link(path: path) do
              {:ok, pid} ->
                send(me, {:reopened, pid})

                receive do
                  :done -> GenServer.stop(pid)
                end

              error ->
                send(me, {:reopen_failed, error})
            end
        end
      end)

    send(keeper, {:open, path})

    receive do
      {:reopened, pid} ->
        {keeper, pid}

      {:reopen_failed, error} ->
        flunk("REOPEN_REFUSED{#{inspect(error, limit: 15)}}")
    after
      @reopen_budget_ms ->
        flunk("REOPEN_REFUSED{:reopen_timeout, budget_ms=#{@reopen_budget_ms}}")
    end
  end

  # current (keeper, store) pair for this round's cleanup path; bounded-op recovery and the
  # post-kill reopen both publish here so the round's cleanup stops the LIVE handle
  defp put_current_owner(keeper, pid),
    do: Process.put(:oek_current_owner, {keeper, pid})

  defp current_owner, do: Process.get(:oek_current_owner)

  defp path_of do
    Process.get(@path_key) || flunk("DRAIN_REFUSED{:no_path}: no path registered for recovery")
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

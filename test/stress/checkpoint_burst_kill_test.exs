defmodule AshPPlan.Reactor.Durable.CheckpointBurstKillTest do
  @moduledoc """
  STRESS: kill window INSIDE the checkpoint write path. Prior soaks killed between ops; here
  8 writers hammer `Engine.attempt` on `Store.Dets` continuously (5-step runs, ~2000
  checkpoints total) while a killer fires 20 kill/reopen rounds at 150ms intervals. Because
  every Dets `handle_call` is `:dets.insert` + `:dets.sync`, a wall-clock kill under that
  load lands mid-`record`/mid-`:dets.sync` with high probability.

  Per-round assertions (in the killer, immediately after each reopen):

    1. No zombie lock: the reopen completes in <10s (typed refusal naming the round otherwise).
    2. Seq monotone across reopen: the post-reopen probe checkpoint's seq strictly exceeds the
       max seq acked before the kill (no counter reset, no lost synced write ahead of it).
    3. Zero acked-write loss for the kill window: every run that acked a write since the
       previous kill still exists with all of its acked attempts' checkpoints intact.
    4. Typed-only failures: writer failures observed in the window are kill-exits or typed
       `{:error, reason}`; a raise/throw is logged as an untyped crash and fails the test.

  A full-court final pass verifies ALL acked writes across all 20 rounds (not just windows),
  drains every run to terminal status, asserts no zombie waiters and `:ended` refusal on
  re-execution.
  """

  use ExUnit.Case, async: false

  @moduletag :stress
  @moduletag timeout: 600_000

  alias AshPPlan.Reactor.Durable.{Engine, Status}
  alias AshPPlan.Reactor.Durable.Store.Dets
  alias AshPPlan.{Realization, Workflow.Model}

  @writers 8
  @rounds 20
  @round_interval_ms 150
  @reopen_budget_ms 10_000
  @steps 5
  @target_checkpoints 2000
  @pt :checkpoint_burst_kill
  @keeper_tab :checkpoint_burst_kill_keepers
  @recovery_tab :checkpoint_burst_kill_recovery

  defmodule Fx do
    @moduledoc false
    use Reactor.Step

    @impl true
    def run(_args, _ctx, opts), do: {:ok, Keyword.fetch!(opts, :effect)}

    @impl true
    def undo(_v, _a, _c, _o), do: :ok
  end

  defmodule Adapter do
    @moduledoc false
    @behaviour AshPPlan.Reactor.Adapter

    @impl true
    def id, do: :cbk_fx

    @impl true
    def available?, do: true

    @impl true
    def ops, do: [:write]

    @impl true
    def step(:write, options),
      do: {:ok, {AshPPlan.Reactor.Durable.CheckpointBurstKillTest.Fx, options}}
  end

  setup do
    previous = Application.get_env(:ash_pplan, :extra_adapters, %{})

    Application.put_env(
      :ash_pplan,
      :extra_adapters,
      Map.put(
        Map.new(previous),
        :cbk_fx,
        AshPPlan.Reactor.Durable.CheckpointBurstKillTest.Adapter
      )
    )

    on_exit(fn -> Application.put_env(:ash_pplan, :extra_adapters, previous) end)

    :ets.new(@keeper_tab, [:named_table, :public, :set]) ||
      :ok

    path =
      Path.join(
        System.tmp_dir!(),
        "checkpoint-burst-kill-#{System.unique_integer([:positive])}_#{:erlang.phash2(make_ref())}.dets"
      )

    File.rm(path)
    File.rm(path <> ".lock")

    {:ok, dets} = Dets.start_link(path: path)

    :persistent_term.put(@pt, %{
      dets: dets,
      path: path,
      rounds_done: 0,
      stop_at: @rounds,
      last_kill_at: 0,
      untyped: []
    })

    {:ok, _} =
      Agent.start_link(
        fn ->
          %{
            acks: [],
            max_seq: 0,
            counts: %{attempt: 0, start: 0, kill_exit: 0, typed_error: 0, untyped: 0, wedges: 0}
          }
        end,
        name: __MODULE__.Log
      )

    on_exit(fn ->
      :persistent_term.erase(@pt)
      File.rm(path)
      File.rm(path <> ".lock")
    end)

    %{path: path, dets: dets}
  end

  test "8-writer checkpoint burst survives 20 mid-write kill/reopen rounds with zero acked loss" do
    Process.flag(:trap_exit, true)

    writers = for w <- 1..@writers, do: Task.async(fn -> writer(w) end)

    killer =
      Task.async(fn ->
        for round <- 1..@rounds do
          Process.sleep(@round_interval_ms)
          kill_and_reopen(round)
        end

        put_pt(rounds_done: @rounds)
        :ok
      end)

    # if the killer dies mid-storm, writers must stop instead of spinning to the 540s timeout
    killer_mon = Process.monitor(killer.pid)

    spawn(fn ->
      receive do
        {:DOWN, ^killer_mon, _, _, _} -> put_pt(rounds_done: @rounds)
      end
    end)

    tasks = writers ++ [killer]

    for {_ref, res} <- Task.yield_many(tasks, 540_000) do
      case res do
        {:ok, :ok} -> :ok
        {:ok, other} -> flunk("writer/killer failed: #{inspect(other, limit: 20)}")
        {:exit, reason} -> flunk("writer/killer exited: #{inspect(reason, limit: 30)}")
        nil -> flunk("writer/killer timed out")
      end
    end

    final_court()
  end

  # -- killer ------------------------------------------------------------------------------------

  # Retry open with backoff inside the budget; a mid-sync kill can transiently leave the file
  # unopenable. Reports the FIRST transient failure observed so the court keeps the evidence.
  defp reopen_with_retry(me, round, path, remaining, first_error \\ nil) do
    res =
      try do
        Dets.start_link(path: path)
      rescue
        e -> {:raised, e}
      end

    case res do
      {:ok, pid} ->
        IO.puts(
          :stderr,
          "[cbk-keeper] round=#{round} res={:ok, #{inspect(pid)}} retries_used=#{not is_nil(first_error)} " <>
            "first_error=#{inspect(first_error, limit: 6)}"
        )

        send(me, {:reopened, pid})

        receive do
          :done -> GenServer.stop(pid)
        end

      {:error, reason} = other ->
        if remaining > 0 do
          Process.sleep(50)
          reopen_with_retry(me, round, path, remaining - 50, first_error || reason)
        else
          send(me, {:reopen_failed, round, first_error || other})
        end

      other ->
        send(me, {:reopen_failed, round, other})
    end
  end

  # One kill/reopen round. The kill fires on the wall clock under full write load, so it lands
  # inside the checkpoint write path (insert + sync) rather than between ops.
  defp kill_and_reopen(round) do
    old = dets!()
    pre_max = Agent.get(log_name(), & &1.max_seq)
    now_ms = System.monotonic_time(:millisecond)
    put_pt(last_kill_at: now_ms)

    if is_pid(old) and Process.alive?(old) do
      Process.exit(old, :kill)
      wait_until(fn -> not Process.alive?(old) end, 10_000)
    end

    # Reopen under an unlinked keeper: the keeper's link must not tear the reopened store
    # down with the killer task, and the reopen timing IS the zombie-lock assertion.
    t0 = System.monotonic_time(:millisecond)
    me = self()

    keeper =
      spawn(fn ->
        # trap BEFORE start_link: if the open fails (init {:stop, ...}), the store's exit
        # signal would otherwise kill this keeper silently and the killer would see only a
        # timeout instead of the typed open-failure reason.
        Process.flag(:trap_exit, true)

        receive do
          {:open, path} ->
            # A kill inside the write path can transiently leave the file unopenable
            # ({:not_a_dets_file, ...}) while the dead owner's tail flush settles; a real
            # supervisor retries. Retry with backoff inside the zombie-lock budget.
            reopen_with_retry(me, round, path, @reopen_budget_ms)
        end
      end)

    :ets.insert(@keeper_tab, {round, keeper})

    # release the previous round's keeper (its store was the one just killed)
    case round > 1 && :ets.lookup(@keeper_tab, round - 1) do
      [{_, prev_keeper}] when is_pid(prev_keeper) -> send(prev_keeper, :done)
      _ -> :ok
    end

    send(keeper, {:open, pt().path})

    reopened =
      receive do
        {:reopened, pid} ->
          put_pt(dets: pid)
          pid

        {:reopen_failed, ^round, {:error, {:path_in_use, _}}} ->
          tab = AshPPlan.Reactor.Durable.Store.Dets.PathLock
          Process.sleep(200)

          slots =
            case :ets.whereis(tab) do
              :undefined ->
                []

              t ->
                Enum.map(:ets.tab2list(t), fn {p, owner, _tick} ->
                  {p, owner, alive: Process.alive?(owner)}
                end)
            end

          flunk(
            "REOPEN_REFUSED{:path_in_use, round=#{round}} old_alive=#{is_pid(old) and Process.alive?(old)} " <>
              "dets=#{inspect(dets!())} dets_alive=#{is_pid(dets!()) and Process.alive?(dets!())} " <>
              "slots=#{inspect(slots, limit: 20)}"
          )

        {:reopen_failed, ^round, reason} ->
          flunk("REOPEN_REFUSED{:open_failed, round=#{round}, reason=#{inspect(reason)}}")
      after
        @reopen_budget_ms ->
          {:backtrace, bin} =
            case Process.info(keeper, :backtrace) do
              nil -> {:backtrace, "keeper DEAD (was it killed?)"}
              bt -> bt
            end

          flunk(
            "REOPEN_REFUSED{:zombie_lock, round=#{round}, budget_ms=#{@reopen_budget_ms}}\n" <>
              "keeper alive=#{Process.alive?(keeper)} backtrace:\n" <> bin
          )
      end

    reopen_ms = System.monotonic_time(:millisecond) - t0

    assert reopen_ms < @reopen_budget_ms,
           "round #{round}: reopen took #{reopen_ms}ms (zombie lock)"

    # seq monotone across reopen: the first write on the reopened store must exceed every seq
    # acked before the kill (the counter is synced with the data, never reset).
    {:ok, probe} =
      Dets.record(reopened, "probe-run", "round-#{round}", "probe", {:round, round}, %{})

    assert probe.seq > pre_max,
           "round #{round}: seq not monotone across reopen (probe=#{probe.seq}, pre-kill max=#{pre_max})"

    Agent.update(log_name(), fn s -> %{s | max_seq: max(s.max_seq, probe.seq)} end)

    # zero acked-write loss in the kill window: everything acked since the previous kill must
    # already be durable and present on the reopened store. Starts demand existence; attempts
    # demand checkpoints.
    window =
      Agent.get(log_name(), fn s -> Enum.filter(s.acks, fn a -> a.at > now_ms end) end)

    started = window |> Enum.filter(&(&1.kind == :start)) |> MapSet.new(& &1.run)

    for run_id <- started do
      assert Engine.fetch(reopened, run_id, store_module: Dets) != nil,
             "round #{round}: lost acked run #{run_id}"
    end

    for {run_id, attempts} <- window_runs(window) do
      case Engine.fetch(reopened, run_id, store_module: Dets) do
        nil ->
          flunk("round #{round}: lost acked run #{run_id} (#{attempts} acked attempts)")

        _rec ->
          cps = Dets.checkpoints(reopened, run_id)

          assert map_size(cps) >= attempts,
                 "round #{round}: run #{run_id} has #{map_size(cps)} checkpoints, " <>
                   "#{attempts} attempts were acked before the kill"
      end
    end

    IO.puts(
      "[cbk] round=#{round} reopen_ms=#{reopen_ms} probe_seq=#{probe.seq} pre_max=#{pre_max} " <>
        "window_runs=#{map_size(window_runs(window))}"
    )
  end

  # -- writers -----------------------------------------------------------------------------------

  defp writer(w) do
    :rand.seed(:exsss, {31 + w, w * 13, 7})
    writer_loop(w)
  end

  defp writer_loop(w) do
    log = Agent.get(log_name(), & &1)

    if pt().rounds_done >= @rounds and log.counts.attempt >= @target_checkpoints / 2 do
      :ok
    else
      run_one(w)
      writer_loop(w)
    end
  end

  # One full 5-step run, continuously. Kill-straddling calls exit; the run is abandoned (its
  # acked prefix is courted in the window check and the final court) and the writer starts a
  # fresh run against the reopened store.
  defp run_one(w) do
    id = "cbk-w#{w}-#{System.unique_integer([:positive])}"

    case bounded("start #{id}", 30_000, fn ->
           Engine.start(dets!(), spine(id), store_module: Dets)
         end) do
      {:ok, {:ok, rec}} ->
        log_ack(:start, id, rec.seq)
        drive(id, 0)

      {:ok, other} ->
        log_typed(:start, id, other)

      :timeout ->
        log_wedge()
        recover_store()
    end
  rescue
    e ->
      log_untyped(:raised, inspect(e, limit: 15), w)
  catch
    :throw, {:store_exit, reason} ->
      if store_exit?(reason), do: log_kill_exit(), else: log_untyped(:store_exit, reason, w)
  end

  defp drive(_id, n) when n >= 2 * @steps + 3, do: log_untyped(:no_progress, :no_progress, 0)

  defp drive(id, n) do
    case bounded("attempt #{id}", 30_000, fn ->
           Engine.attempt(dets!(), id, store_module: Dets, lease_ms: 5_000)
         end) do
      {:ok, :ended} ->
        :ok

      {:ok, {:parked, _}} ->
        :ok

      {:ok, {:ok, _rec}} ->
        log_ack(:attempt, id)
        drive(id, n + 1)

      {:ok, {:completed, _step}} ->
        log_ack(:attempt, id)

      {:ok, {:error, reason}} ->
        log_typed(:attempt, id, reason)

      {:ok, {:failed, reason}} ->
        log_typed(:failed, id, reason)

      :timeout ->
        log_wedge()
        recover_store()
    end
  end

  # bounded/3: run fun in a supervised task; a store wedge (alive server, :infinity call that
  # never replies) pins a writer forever otherwise. A timeout is brutal-killed, counted as a
  # wedge, and triggers recovery — never an untyped failure of the writer itself.
  defp bounded(label, timeout_ms, fun) do
    task =
      Task.async(fn ->
        try do
          {:ok, fun.()}
        rescue
          e -> {:raised, e}
        catch
          :exit, e -> {:exit_caught, e}
        end
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, {:ok, v}} ->
        {:ok, v}

      {:ok, {:raised, e}} ->
        raise e

      {:ok, {:exit_caught, e}} ->
        throw({:store_exit, e})

      nil ->
        Task.shutdown(task, :brutal_kill)
        IO.puts(:stderr, "[cbk-wedge] #{label} exceeded #{timeout_ms}ms")
        :timeout
    end
  end

  defp log_wedge, do: Agent.update(log_name(), fn s -> update_in(s.counts.wedges, &(&1 + 1)) end)

  # -- wedge recovery -----------------------------------------------------------------------------

  defp wedged?(store) do
    try do
      GenServer.call(store, {:get_run, "__ping__"}, 2_000)
      false
    catch
      :exit, _ -> true
    end
  end

  # One recovery at a time via an ETS lock; everyone else keeps retrying against pt().dets,
  # which the recovery swaps atomically. Mirrors the killer's keeper-open path.
  defp recover_store do
    unless :ets.insert_new(@recovery_tab, {:lock, System.unique_integer([:positive])}) do
      Process.sleep(100)
    else
      try do
        old = dets!()

        if is_pid(old) and Process.alive?(old) and wedged?(old) do
          Process.exit(old, :kill)
          wait_until(fn -> not Process.alive?(old) end, 10_000)
          Process.sleep(100)
        end

        unless is_pid(dets!()) and Process.alive?(dets!()) and not wedged?(dets!()) do
          me = self()

          keeper =
            spawn(fn ->
              Process.flag(:trap_exit, true)

              receive do
                {:open, path} ->
                  case Dets.start_link(path: path) do
                    {:ok, pid} ->
                      send(me, {:reopened, pid})

                      receive do
                        :done -> GenServer.stop(pid)
                      end

                    other ->
                      send(me, {:reopen_failed, other})
                  end
              end
            end)

          send(keeper, {:open, pt().path})

          receive do
            {:reopened, pid} ->
              :ets.insert(@keeper_tab, {:recovery, keeper})
              put_pt(dets: pid)

            {:reopen_failed, reason} ->
              flunk("RECOVERY_REFUSED{:open_failed, reason=#{inspect(reason, limit: 10)}}")
          after
            @reopen_budget_ms ->
              flunk("RECOVERY_REFUSED{:reopen_timeout}")
          end
        end
      after
        :ets.delete(@recovery_tab, :lock)
      end
    end
  end

  # typed-only failures: a store mid-kill answers with a plain exit (:killed / noproc from the
  # dead GenServer). Anything else is untyped and fails the court.
  defp store_exit?(reason) do
    case reason do
      {:killed, _} -> true
      :killed -> true
      {:noproc, _} -> true
      :noproc -> true
      :normal -> true
      _ -> false
    end
  end

  # -- final court -------------------------------------------------------------------------------

  defp final_court do
    store = dets!()
    log = Agent.get(log_name(), & &1)
    acks = Enum.reverse(log.acks)

    runs =
      Enum.reduce(acks, %{}, fn
        %{kind: :attempt, run: r}, acc -> Map.update(acc, r, 1, &(&1 + 1))
        %{kind: :start, run: r}, acc -> Map.put(acc, r, Map.get(acc, r, 0))
      end)

    IO.puts(
      "[cbk] acks=#{length(acks)} runs=#{map_size(runs)} kill_exits=#{log.counts.kill_exit} " <>
        "typed_errors=#{log.counts.typed_error} max_seq=#{log.max_seq}"
    )

    assert log.counts.untyped == 0 and pt().untyped == [],
           "untyped failures observed: #{inspect(pt().untyped, limit: 10)}"

    assert log.counts.kill_exit > 0,
           "no kill-straddling call was ever observed - the kill window missed the write path"

    # drain every run to terminal, bounded
    drain(runs |> Map.keys() |> Enum.sort(), 3)

    # full-court zero-loss: every acked write across all 20 rounds is present and intact
    for {run_id, attempts} <- runs do
      assert %{} = Engine.fetch(store, run_id, store_module: Dets), "lost run #{run_id}"
      cps = Dets.checkpoints(store, run_id)

      assert map_size(cps) >= attempts,
             "run #{run_id}: #{map_size(cps)} checkpoints < #{attempts} acked attempts"

      seqs = cps |> Map.values() |> Enum.map(& &1.seq) |> Enum.sort()

      assert seqs == Enum.uniq(seqs),
             "run #{run_id}: checkpoint seqs not strictly increasing"

      assert Status.terminal?(fetch_status(store, run_id)),
             "run #{run_id} never reached a terminal status: #{inspect(fetch_status(store, run_id))}"

      assert Dets.waiters(store, run_id) == [], "zombie waiters on run #{run_id}"

      assert :ended = Engine.attempt(store, run_id, store_module: Dets),
             "terminal run #{run_id} did not refuse re-execution"
    end

    assert log.counts.attempt >= @target_checkpoints / 4,
           "checkpoint volume too low: #{log.counts.attempt} acked attempts (~1+ checkpoint each)/#{@target_checkpoints}"

    # final store still serves and its seq counter dominates every acked seq
    {:ok, last} = Dets.record(store, "probe-run", "final", "probe", :final, %{})
    assert last.seq >= log.max_seq

    # release keepers + final store
    for {_, k} <- :ets.tab2list(@keeper_tab), is_pid(k), do: send(k, :done)

    if is_pid(d = dets!()) and Process.alive?(d), do: GenServer.stop(d)
  end

  defp drain(_runs, 0), do: flunk("DRAIN_REFUSED{runs never reached terminal status}")

  defp drain(runs, passes) do
    store = dets!()
    remaining = Enum.filter(runs, &(not Status.terminal?(fetch_status(store, &1))))

    if remaining == [] do
      :ok
    else
      Enum.each(remaining, fn id ->
        try do
          Engine.attempt(store, id, store_module: Dets, lease_ms: 5_000)
        catch
          :exit, _ -> :ok
        end
      end)

      Process.sleep(50)
      drain(runs, passes - 1)
    end
  end

  # -- bookkeeping ---------------------------------------------------------------------------------

  defp log_ack(:start, id, seq) do
    now = System.monotonic_time(:millisecond)

    Agent.update(log_name(), fn s ->
      %{s | max_seq: max(s.max_seq, seq), acks: [%{kind: :start, run: id, at: now} | s.acks]}
    end)

    Agent.update(log_name(), fn s -> update_in(s.counts.start, &(&1 + 1)) end)
  end

  defp log_ack(:attempt, id) do
    now = System.monotonic_time(:millisecond)

    Agent.update(log_name(), fn s ->
      %{s | acks: [%{kind: :attempt, run: id, at: now} | s.acks]}
    end)
  end

  defp log_typed(_op, _id, _reason),
    do: Agent.update(log_name(), fn s -> update_in(s.counts.typed_error, &(&1 + 1)) end)

  defp log_kill_exit,
    do: Agent.update(log_name(), fn s -> update_in(s.counts.kill_exit, &(&1 + 1)) end)

  defp log_untyped(kind, reason, id) do
    Agent.update(log_name(), fn s -> update_in(s.counts.untyped, &(&1 + 1)) end)
    put_pt(untyped: [{kind, id, inspect(reason, limit: 20)} | pt().untyped])
  end

  # collapse attempt acks into %{run_id => acked attempt count}
  defp window_runs(window) do
    window
    |> Enum.filter(&(&1.kind == :attempt))
    |> Enum.reduce(%{}, fn %{run: run}, acc -> Map.update(acc, run, 1, &(&1 + 1)) end)
  end

  # -- spine --------------------------------------------------------------------------------------

  defp spine(id) do
    tids = for i <- 0..(@steps - 1), do: String.to_atom("s#{i}")

    specs =
      tids
      |> Enum.with_index()
      |> Enum.map(fn {tid, i} ->
        base = [id: tid, capability: "File.Write", authority: :construct]

        if i == 0, do: base, else: base ++ [after: [Enum.at(tids, i - 1)]]
      end)

    {:ok, model} = Model.new(name: "cbk-#{id}", goal: "g", tasks: specs)

    bindings =
      Map.new(tids, fn tid ->
        {tid,
         %Realization{
           capability: "File.Write",
           provider: :cbk_fx,
           binding: %{adapter: :cbk_fx, op: :write},
           options: [effect: tid]
         }}
      end)

    %{id: id, model: model, bindings: bindings, inputs: %{input: %{}}, context: %{}, parent: nil}
  end

  # -- plumbing -------------------------------------------------------------------------------------

  defp log_name, do: __MODULE__.Log

  defp fetch_status(store, id) do
    case Engine.fetch(store, id, store_module: Dets) do
      %{status: s} -> s
      nil -> :not_found
    end
  end

  defp dets!, do: pt().dets

  defp pt, do: :persistent_term.get(@pt)

  defp put_pt(kvs), do: :persistent_term.put(@pt, Map.merge(pt(), Map.new(kvs)))

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

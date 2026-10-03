defmodule AshPPlan.Reactor.Durable.EngineCancelStormTest do
  @moduledoc """
  STRESS: 16 workers hammer the real `Engine` on the real `Store.Dets` with mixed lifecycle
  churn — start → attempt (parks on a real `Steps.Await` waiter) → random(cancel | signal |
  attempt again) → settle — 512 acknowledged ops total, cancels racing attempts and signals
  racing cancels, seeded.

  Mid-storm the Dets server is hard-killed and reopened on the same `:path`. The kill is
  deterministic: it fires on a barrier (every worker acked readiness AND >= 1 acked op), the
  killer owns its deadline (a miss is a typed refusal), and every op runs under a bounded
  timeout. Invariants,
  verified after a drain pass (attempts scheduled AFTER the cancels, per the level-triggered
  unwind semantics — a `:cancelling` run is unwound by the next attempt, never by a message):

    1. No run left in `:cancelling` (or any non-terminal status) forever: every run reaches a
       terminal status (`completed | failed | cancelled`) after the drain.
    2. No zombie waiters: every terminal run has `waiters == []`.
    3. `seq` strictly monotone across the kill: the acked post-reopen seqs strictly exceed
       the acked pre-kill seqs.
    4. The store survives: the reopened server serves every run, and each terminal run refuses
       re-execution (`Engine.attempt -> :ended`).
  """

  use ExUnit.Case, async: false

  @moduletag :stress
  @moduletag timeout: 900_000

  alias AshPPlan.Reactor.Durable.{Engine, Status}
  alias AshPPlan.Reactor.Durable.Store.Dets
  alias AshPPlan.{Realization, Workflow.Model}

  @workers 16
  @ops_per_worker 32
  @total_ops @workers * @ops_per_worker
  # Kill determinism: the kill fires on the barrier (every worker acked readiness AND at least
  # one op acked), never on a raw ops threshold — a throughput-coupled gate (kill at half the
  # ops) is exactly what starved: under store contention the op pipeline can crawl or wedge, so
  # the killer waited out its whole 480s while ops sat at ~100.
  @barrier_deadline_ms 120_000
  @op_timeout_ms 30_000
  @pt :engine_cancel_storm
  @recovery_tab :engine_cancel_storm_recovery

  defmodule Fx do
    @moduledoc false
    use Reactor.Step

    @impl true
    def run(_args, _ctx, opts) do
      Process.sleep(:rand.uniform(3))
      {:ok, Keyword.fetch!(opts, :effect)}
    end

    @impl true
    def undo(_v, _a, _c, _o), do: :ok
  end

  setup do
    previous = Application.get_env(:ash_pplan, :extra_adapters, %{})

    Application.put_env(
      :ash_pplan,
      :extra_adapters,
      Map.put(Map.new(previous), :cancel_storm_fx, Adapter)
    )

    on_exit(fn -> Application.put_env(:ash_pplan, :extra_adapters, previous) end)

    path =
      Path.join(
        System.tmp_dir!(),
        "engine-cancel-storm-#{System.unique_integer([:positive])}.dets"
      )

    File.rm(path)
    File.rm(path <> ".lock")

    {:ok, dets} = Dets.start_link(path: path)

    :persistent_term.put(@pt, %{
      dets: dets,
      path: path,
      killer_done: false,
      workers: [],
      ready: MapSet.new(),
      keepers: []
    })

    {:ok, _} =
      Agent.start_link(
        fn ->
          %{ops: 0, seqs_pre: [], seqs_post: [], seen_ids: MapSet.new(), runs: [], crashes: []}
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

  test "16-worker cancel storm over Dets survives a hard kill and reopen with all invariants" do
    Process.flag(:trap_exit, true)

    workers = for w <- 1..@workers, do: Task.async(fn -> worker(w) end)
    :persistent_term.put(@pt, Map.put(pt(), :workers, Enum.map(workers, & &1.pid)))

    killer =
      Task.async(fn ->
        t0 = System.monotonic_time(:millisecond)

        # Barrier: all workers acked readiness AND >= 1 op acked. Supervised by its own
        # deadline; a miss is a typed refusal naming the barrier state, not a 480s hang.
        wait_barrier(t0)

        IO.puts(
          "[storm] barrier open after #{div(System.monotonic_time(:millisecond) - t0, 1000)}s"
        )

        killed = pt().dets

        if is_pid(killed) and Process.alive?(killed) do
          Process.exit(killed, :kill)
          wait_until(fn -> not Process.alive?(killed) end, 10_000)
        end

        # the reopened store needs a parent that outlives this task: an unlink-then-exit from
        # the killer can deliver the killer's :normal exit signal to the store AFTER unlink/1
        # returns (erlang:unlink/1 does not drain in-flight exit signals), and a trap_exit
        # GenServer terminates on its parent's exit - witnessed as GenServer.call -> EXIT
        # normal against a freshly reopened store
        me = self()

        keeper =
          spawn(fn ->
            receive do
              {:open, path} ->
                res = Dets.start_link(path: path)

                case res do
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

        send(keeper, {:open, pt().path})

        reopened =
          receive do
            {:reopened, pid} -> pid
            {:reopen_failed, error} -> flunk("reopen failed: #{inspect(error, limit: 20)}")
          after
            30_000 -> flunk("reopened store did not come up")
          end

        put_pt(dets: reopened, killer_done: true, keepers: [keeper | pt().keepers])
        :ok
      end)

    tasks = workers ++ [killer]

    for {_ref, res} <- Task.yield_many(tasks, 840_000) do
      case res do
        {:ok, :ok} -> :ok
        {:ok, other} -> flunk("worker/failed: #{inspect(other)}")
        {:exit, reason} -> flunk("worker/killer exited: #{inspect(reason)}")
        nil -> report_stall()
      end
    end

    unless pt().killer_done do
      %{ops: ops} = Agent.get(__MODULE__.Log, & &1)
      flunk("storm ops finished but killer never reopened: ops=#{ops}")
    end

    storm_runs = Agent.get(__MODULE__.Log, & &1.runs) |> Enum.reverse()
    assert storm_runs != []

    drain_and_verify(storm_runs)
    verify_seqs()

    # release the keepers and the final reopened store now that the court is done
    for k <- pt().keepers, is_pid(k), do: send(k, :done)
    if is_pid(d = pt().dets) and Process.alive?(d), do: GenServer.stop(d)
  end

  defp report_stall do
    %{ops: ops, crashes: crashes} = Agent.get(__MODULE__.Log, & &1)
    dets = pt().dets

    IO.puts("""
    [stall-dump] ops=#{ops} killer_done=#{pt().killer_done} crashes=#{inspect(Enum.take(crashes, 3), limit: 20)}
    [stall-dump] dets=#{inspect(dets)} alive=#{is_pid(dets) and Process.alive?(dets)}
    """)

    if is_pid(dets) and Process.alive?(dets) do
      {:backtrace, bin} = Process.info(dets, :backtrace)
      IO.puts(["[stall-dump] dets backtrace:\n", bin])
    end

    for pid <- pt().workers, is_pid(pid) do
      {:backtrace, bin} = Process.info(pid, :backtrace)
      IO.puts(["[stall-dump] worker #{inspect(pid)} backtrace:\n", bin])
    end

    flunk("storm did not finish: ops=#{ops} killer_done=#{pt().killer_done}")
  end

  # -- workers ---------------------------------------------------------------------------------

  defp worker(w) do
    :rand.seed(:exsss, {1000 + w, w * 77, 42})
    loop(w, 0, [])
  end

  # One acked Engine lifecycle op per iteration; kill-straddling calls are abandoned,
  # uncounted, and retried against the reopened store.
  defp loop(_w, seen, _mine) when seen >= @ops_per_worker, do: :ok

  defp loop(w, seen, mine) do
    if ops_done() >= @total_ops do
      :ok
    else
      case bounded_churn(w, seen, mine) do
        {:acked, mine2} ->
          count_op()
          mark_ready(w)
          loop(w, seen + 1, mine2)

        :retry ->
          # never hot-spin: a retry round hits the store with terminal? fetches, and a tight
          # loop here starves the acked-op pipeline the killer's gate waits on
          Process.sleep(1)
          loop(w, seen, mine)
      end
    end
  end

  # Bounded per-op execution: one op runs in its own supervised task with a hard deadline. A
  # wedged store call (GenServer.call timeouts are :infinity in Dets) can otherwise pin a
  # worker forever and freeze the whole pipeline; here a miss is brutal-killed, counted as a
  # crash, and retried. The op is uncounted, so acked-writes invariants stay honest.
  defp bounded_churn(w, seen, mine) do
    task = Task.async(fn -> churn(w, seen, mine) end)

    case Task.yield(task, @op_timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        log_crash(%{kind: :op_timeout, reason: "op exceeded #{@op_timeout_ms}ms"})
        recover_if_broken()
        :retry

      {:exit, reason} ->
        log_crash(%{kind: :op_exit, reason: inspect(reason, limit: 30)})
        recover_if_broken()
        :retry
    end
  end

  defp log_crash(crash) do
    Agent.update(__MODULE__.Log, fn s -> %{s | crashes: [crash | s.crashes]} end)
  end

  # -- wedge recovery ---------------------------------------------------------------------------
  # The reopened (repaired) dets file can wedge its server inside a traversal helper wait
  # (:dets.match_delete via release_all -> dets:req/2 on a helper that never replies). A wedged
  # server pins every caller (GenServer.call timeouts are :infinity), so recovery is part of the
  # storm: detect a live-but-unresponsive server, kill it, and reopen on the same :path — the
  # same transition the planned kill exercises. One recovery at a time (ETS lock); everyone else
  # keeps retrying against pt().dets, which the recovery swaps atomically.

  defp recover_if_broken do
    store = pt().dets

    cond do
      is_pid(store) and Process.alive?(store) and wedged?(store) ->
        log_crash(%{kind: :store_wedge, reason: "server alive but unresponsive to health ping"})
        recover_store()

      is_pid(store) and not Process.alive?(store) and pt().killer_done ->
        # a stray death after the planned kill: reopen like the killer does
        recover_store()

      true ->
        :ok
    end
  end

  defp wedged?(store) do
    try do
      GenServer.call(store, {:get_run, "__ping__"}, 2_000)
    catch
      :exit, _ -> true
    else
      _ -> false
    end
  end

  defp recover_store do
    unless :ets.insert_new(@recovery_tab, {:lock, System.unique_integer([:positive])}) do
      # another recovery is in flight; it will swap pt().dets when it lands
      Process.sleep(100)
    else
      try do
        old = pt().dets

        if is_pid(old) and Process.alive?(old) do
          Process.exit(old, :kill)
          wait_until(fn -> not Process.alive?(old) end, 10_000)
          # grace so the dead owner's path lock is observed stale by the next opener
          Process.sleep(100)
        end

        me = self()

        keeper =
          spawn(fn ->
            receive do
              {:open, path} ->
                res = Dets.start_link(path: path)

                case res do
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

        send(keeper, {:open, pt().path})

        reopened =
          receive do
            {:reopened, pid} -> pid
          after
            30_000 -> flunk("RECOVERY_REFUSED{:reopen_timeout}")
          end

        put_pt(dets: reopened, keepers: [keeper | pt().keepers])
      after
        :ets.delete(@recovery_tab, :lock)
      end
    end
  end

  defp churn(w, seen, mine) do
    try do
      if rem(seen, 4) == 0 do
        fresh_run(w, seen, mine)
      else
        pick_existing(w, seen, mine)
      end
    catch
      kind, reason ->
        log_crash(%{kind: kind, reason: inspect(reason, limit: 30)})
        :retry
    end
  end

  defp fresh_run(w, seen, mine) do
    # Phase is captured atomically with the store handle: a seq served by the old store but
    # logged after killer_done flips is a PRE-kill seq, not post. Classifying by log time
    # misfiles a pre-kill seq into seqs_post (witnessed as max(pre)=24 < min(post)=17).
    store = dets!()
    phase = pt().killer_done
    id = "storm-w#{w}-r#{seen}"
    {:ok, rec} = Engine.start(store, spine(id), store_module: Dets)
    log_run(id)
    log_seq(id, rec.seq, phase)
    _ = settle_op(store, id)
    {:acked, [id | mine]}
  end

  # Hit a random own run with one random op. A drained live set is PROGRESS, not a skip:
  # seen only advances on acked ops, so a wedged seen ≢ 0 (mod 4) here would spin on :retry
  # forever and freeze the op pipeline (witnessed as the storm stalling at ops=82). Falling
  # through to fresh_run guarantees forward progress.
  defp pick_existing(w, seen, mine) do
    store = dets!()

    if Enum.all?(mine, &terminal?(store, &1)) do
      fresh_run(w, seen, mine)
    else
      id = Enum.random(mine)
      rand_op(store, id)
      {:acked, mine}
    end
  end

  defp rand_op(store, id) do
    case :rand.uniform(3) do
      1 -> Engine.cancel(store, id, store_module: Dets)
      2 -> Engine.signal(store, id, "go", :storm, store_module: Dets)
      _ -> settle_op(store, id)
    end
  end

  defp settle_op(store, id) do
    case Engine.attempt(store, id, store_module: Dets, lease_ms: 500) do
      {:parked, _} ->
        if :rand.uniform(2) == 1 do
          Engine.signal(store, id, "go", :storm, store_module: Dets)
          Engine.attempt(store, id, store_module: Dets, lease_ms: 500)
        end

      _other ->
        :ok
    end

    :ok
  end

  # -- drain + invariants ----------------------------------------------------------------------

  # Every drain-phase sweep runs bounded: on a timeout the store is treated as wedged, recovered
  # (kill + reopen on the same path) and the sweep is redone. Invariants are asserted only on a
  # completed sweep - never skipped - so nothing here weakens them.
  defp drain_and_verify(runs) do
    bounded_sweep("release_all pass", fn store ->
      Enum.each(runs, fn id ->
        try do
          Dets.release_all(store, id)
        catch
          :exit, _ -> :ok
        end
      end)
    end)

    drain_passes(runs, 60)

    bounded_sweep("terminal? scan", fn store ->
      stuck = Enum.filter(runs, &(not terminal?(store, &1)))

      assert stuck == [],
             "#{length(stuck)} runs never reached a terminal status after drain; " <>
               "statuses=#{inspect(Enum.take(Enum.map(stuck, &fetch_status(store, &1)), 10), limit: 30)}"
    end)

    bounded_sweep("cancelling scan", fn store ->
      cancelling =
        Enum.filter(runs, fn id ->
          s = fetch_status(store, id)
          s == :cancelling or Status.rolling_back?(s)
        end)

      assert cancelling == [], "runs still rolling back after drain: #{inspect(cancelling)}"
    end)

    bounded_sweep("zombie waiters scan", fn store ->
      zombies =
        for id <- runs,
            w = Dets.waiters(store, id),
            w != [],
            into: %{} do
          {id, w}
        end

      assert zombies == %{}, "zombie waiters on terminal runs: #{inspect(zombies, limit: 10)}"
    end)

    bounded_sweep(":ended refusal sweep", fn store ->
      for id <- runs do
        assert :ended = Engine.attempt(store, id, store_module: Dets),
               "run #{id} did not refuse re-execution"
      end
    end)
  end

  # A drain sweep runs in its own supervised task; a timeout means the store wedged mid-sweep.
  # Recovery (kill + reopen on the same path), then a redo; after 3 misses the test fails with a
  # typed refusal naming the sweep. An exited sweep is an immediate typed refusal (an assert
  # firing inside the sweep must not be laundered into a retry).
  defp bounded_sweep(label, fun, attempts \\ 3) do
    task = Task.async(fn -> fun.(dets!()) end)

    case Task.yield(task, 120_000) do
      {:ok, _result} ->
        :ok

      {:exit, reason} ->
        flunk("DRAIN_REFUSED{#{label}}: sweep exited: #{inspect(reason, limit: 20)}")

      nil ->
        Task.shutdown(task, :brutal_kill)
        recover_if_broken()

        if attempts <= 1 do
          flunk("DRAIN_REFUSED{#{label}}: store wedged on every attempt")
        else
          bounded_sweep(label, fun, attempts - 1)
        end
    end
  end

  defp drain_passes(_runs, 0), do: :ok

  defp drain_passes(runs, remaining) do
    {done, _} =
      bounded_op("drain pass", fn store ->
        nonterminal = Enum.filter(runs, &(not terminal?(store, &1)))

        Enum.each(nonterminal, fn id ->
          try do
            Engine.attempt(store, id, store_module: Dets, lease_ms: 500)
          catch
            :exit, _ -> :ok
          end
        end)

        nonterminal == []
      end)

    if done do
      :ok
    else
      Process.sleep(50)
      drain_passes(runs, remaining - 1)
    end
  end

  # bounded_op: like bounded_sweep but returns {:ok, value} on success; on timeout: brutal-kill,
  # recover the store, redo; after 3 misses a typed refusal. An exited fun is a typed refusal.
  defp bounded_op(label, fun, attempts \\ 3) do
    task = Task.async(fn -> fun.(dets!()) end)

    case Task.yield(task, 120_000) do
      {:ok, value} ->
        {:ok, value}

      {:exit, reason} ->
        flunk("DRAIN_REFUSED{#{label}}: exited: #{inspect(reason, limit: 20)}")

      nil ->
        Task.shutdown(task, :brutal_kill)
        recover_if_broken()

        if attempts <= 1 do
          flunk("DRAIN_REFUSED{#{label}}: store wedged on every attempt")
        else
          bounded_op(label, fun, attempts - 1)
        end
    end
  end

  defp verify_seqs do
    %{seqs_pre: pre, seqs_post: post} = Agent.get(__MODULE__.Log, & &1)

    assert pre != [] and post != [],
           "no seqs logged (pre: #{length(pre)}, post: #{length(post)})"

    assert Enum.max(pre) < Enum.min(post),
           "seq not monotone across kill/reopen: max(pre)=#{Enum.max(pre)}, min(post)=#{Enum.min(post)}"
  end

  # -- spine -----------------------------------------------------------------------------------

  defp spine(id) do
    tasks = [
      {:a, "File.Write", :file_write},
      {:b, "File.Write", :file_write},
      {:wait, "Human.Approve", :human_approve}
    ]

    specs =
      tasks
      |> Enum.with_index()
      |> Enum.map(fn {{tid, cap, _op}, i} ->
        base = [id: tid, capability: cap, authority: :construct]

        if i == 0,
          do: base,
          else: base ++ [after: [elem(Enum.at(tasks, i - 1), 0)]]
      end)

    {:ok, model} = Model.new(name: "cancel-storm-#{id}", goal: "g", tasks: specs)

    bindings =
      Map.new(tasks, fn {tid, cap, op} ->
        {tid,
         %Realization{
           capability: cap,
           provider: :cancel_storm_fx,
           binding: %{adapter: :cancel_storm_fx, op: op},
           options: [effect: tid]
         }}
      end)

    %{id: id, model: model, bindings: bindings, inputs: %{input: %{}}, context: %{}, parent: nil}
  end

  # -- plumbing ----------------------------------------------------------------------------------

  defp terminal?(store, id) do
    case Engine.fetch(store, id, store_module: Dets) do
      nil -> true
      %{status: s} -> Status.terminal?(s)
    end
  end

  defp fetch_status(store, id) do
    case Engine.fetch(store, id, store_module: Dets) do
      %{status: s} -> s
      nil -> :not_found
    end
  end

  defp log_run(id), do: Agent.update(__MODULE__.Log, &%{&1 | runs: [id | &1.runs]})

  # Dedupe by run id: a kill-straddling Engine.start retry re-returns the record created
  # pre-kill (start_run is idempotent by id, seq included) - logging it again would misfile a
  # pre-kill seq into seqs_post (witnessed as max(pre)=25 < min(post)=17).
  defp log_seq(id, seq, phase) do
    Agent.get_and_update(__MODULE__.Log, fn s ->
      if id in s.seen_ids do
        {nil, s}
      else
        s2 =
          if phase,
            do: %{s | seen_ids: MapSet.put(s.seen_ids, id), seqs_post: [seq | s.seqs_post]},
            else: %{s | seen_ids: MapSet.put(s.seen_ids, id), seqs_pre: [seq | s.seqs_pre]}

        {nil, s2}
      end
    end)
  end

  defp ops_done, do: Agent.get(__MODULE__.Log, & &1.ops)

  # -- kill barrier ------------------------------------------------------------------------------

  defp mark_ready(w) do
    put_pt(ready: MapSet.put(pt().ready, w))
  end

  # Killer-owned barrier deadline: a miss refuses with a typed reason instead of hanging to the
  # module timeout, so a wedged pipeline surfaces in <= @barrier_deadline_ms with its state.
  defp wait_barrier(t0) do
    deadline = System.monotonic_time(:millisecond) + @barrier_deadline_ms

    wait_barrier_loop(t0, deadline)
  end

  defp wait_barrier_loop(t0, deadline) do
    ops = ops_done()

    if rem(ops, 100) == 0 and ops > 0 do
      elapsed = System.monotonic_time(:millisecond) - t0

      IO.puts(
        "[storm] ops=#{ops} runs=#{run_count()} ready=#{ready_count()} #{div(elapsed, 1000)}s"
      )
    end

    cond do
      barrier_open?() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk(
          "KILLER_REFUSED{:barrier_timeout, ready=#{ready_count()}/#{@workers}, ops=#{ops}, " <>
            "runs=#{run_count()}}"
        )

      true ->
        Process.sleep(50)
        wait_barrier_loop(t0, deadline)
    end
  end

  defp ready_count, do: MapSet.size(pt().ready)

  # The kill fires only when the whole storm is in motion: every worker has acked at least one
  # op (its readiness) AND the op counter is >= 1. This is a state barrier, not a race on wall
  # clock or throughput.
  defp barrier_open?, do: ready_count() >= @workers and ops_done() >= 1

  defp run_count, do: Agent.get(__MODULE__.Log, &length(&1.runs))

  defp count_op, do: Agent.update(__MODULE__.Log, &%{&1 | ops: &1.ops + 1})

  defp dets!, do: :persistent_term.get(@pt).dets

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
      Process.sleep(50)
      wait_until_loop(fun, deadline)
    end
  end
end

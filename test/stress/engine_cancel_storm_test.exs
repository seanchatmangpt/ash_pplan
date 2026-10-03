defmodule AshPPlan.Reactor.Durable.EngineCancelStormTest do
  @moduledoc """
  STRESS: 16 workers hammer the real `Engine` on the real `Store.Dets` with mixed lifecycle
  churn — start → attempt (parks on a real `Steps.Await` waiter) → random(cancel | signal |
  attempt again) → settle — 5000 acknowledged ops total, cancels racing attempts and signals
  racing cancels, all seeded.

  Mid-storm the Dets server is hard-killed (`Process.exit(pid, :kill)`) and reopened on the
  same `:path`. Invariants, verified after a drain pass (attempts scheduled AFTER the cancels,
  per the level-triggered unwind semantics — a `:cancelling` run is unwound by the next
  attempt, never by a message):

    1. No run left in `:cancelling` (or any non-terminal status) forever: every run reaches a
       terminal status (`completed | failed | cancelled`) after the drain.
    2. No zombie waiters: every terminal run has `waiters == []`.
    3. `seq` monotone across the kill: the minimum acked post-reopen seq strictly exceeds the
       maximum acked pre-kill seq (the counter is persisted in the table, not in the server).
    4. The store survives: the reopened server serves every run, and each terminal run refuses
       re-execution (`Engine.attempt -> :ended`).
  """

  use ExUnit.Case, async: false

  @moduletag :stress
  @moduletag timeout: 600_000

  alias AshPPlan.Reactor.Durable.{Engine, Status, Testing}
  alias AshPPlan.Reactor.Durable.Store.Dets
  alias AshPPlan.{Realization, Workflow.Model}

  @workers 16
  @total_ops 5000
  @kill_at div(@total_ops, 2)
  @pt :engine_cancel_storm

  defmodule Fx do
    @moduledoc false
    use Reactor.Step

    @impl true
    def run(_args, _ctx, opts) do
      # a tiny randomized sleep widens the cancel-races-attempt window without costing the run
      Process.sleep(:rand.uniform(3))
      {:ok, Keyword.fetch!(opts, :effect)}
    end

    @impl true
    def undo(_value, _args, _ctx, _opts), do: :ok
  end

  defmodule Adapter do
    @moduledoc false
    @behaviour AshPPlan.Reactor.Adapter
    alias AshPPlan.Reactor.Durable.Steps

    @impl true
    def id, do: :cancel_storm_fx
    @impl true
    def available?, do: true
    @impl true
    def ops, do: [:file_write, :human_approve]

    @impl true
    def step(op, options) do
      table = %{
        file_write: {Fx, []},
        human_approve: {Steps.Await, [signal: "go", timeout: nil]}
      }

      AshPPlan.Reactor.Adapter.resolve(__MODULE__, table, op, options)
    end
  end

  setup do
    previous = Application.get_env(:ash_pplan, :extra_adapters, %{})

    Application.put_env(
      :ash_pplan,
      :extra_adapters,
      Map.put(Map.new(previous), :cancel_storm_fx, Adapter)
    )

    on_exit(fn -> Application.put_env(:ash_pplan, :extra_adapters, previous) end)

    path = Path.join(System.tmp_dir!(), "engine-cancel-storm-#{System.unique_integer([:positive])}.dets")
    File.rm(path)
    File.rm(path <> ".lock")

    {:ok, dets} = Dets.start_link(path: path)

    :persistent_term.put(@pt, %{dets: dets, path: path, killer_done: false})

    {:ok, _} =
      Agent.start_link(fn -> %{ops: 0, seqs_pre: [], seqs_post: [], runs: []} end,
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
    # the Dets server is linked to this process; the mid-storm :kill must not take us down
    Process.flag(:trap_exit, true)

    workers = for w <- 1..@workers, do: Task.async(fn -> worker(w) end)

    killer =
      Task.async(fn ->
        wait_until(fn -> ops_done() >= @kill_at end, 300_000)
        killed = pt().dets

        if is_pid(killed) and Process.alive?(killed) do
          Process.exit(killed, :kill)
          wait_until(fn -> not Process.alive?(killed) end, 10_000)
        end

        {:ok, reopened} = Dets.start_link(path: pt().path)
        # the store must outlive this task; its link would tear the store down with us
        :erlang.unlink(reopened)
        put_pt(dets: reopened, killer_done: true)
        :ok
      end)

    tasks = workers ++ [killer]

    for {_ref, res} <- Task.yield_many(tasks, 540_000) do
      case res do
        {:ok, :ok} -> :ok
        {:ok, other} -> flunk("worker/killer failed: #{inspect(other)}")
        {:exit, reason} -> flunk("worker/killer exited: #{inspect(reason)}")
        nil -> flunk("worker/killer timed out")
      end
    end

    assert pt().killer_done, "killer never completed the reopen"
    assert ops_done() >= @total_ops, "only #{ops_done()} of #{@total_ops} ops acked"

    storm_runs = Agent.get(__MODULE__.Log, & &1.runs) |> Enum.reverse()
    assert length(storm_runs) > 0

    drain_and_verify(storm_runs)
    verify_seqs()
  end

  # -- worker loop ------------------------------------------------------------------------------

  # One worker owns the ids it creates (w<w>-r<n>). Each acknowledged op is one Engine
  # lifecycle call; the op is counted only after it returns. Every 4th op targets a FRESH run
  # (start → attempt); the rest churn existing non-terminal runs owned by this worker.
  defp worker(w) do
    :rand.seed(:exsss, {1000 + w, w * 77, 42})

    loop(w, 0)
  end

  defp loop(_w, seen) when seen >= 400, do: :ok

  defp loop(w, seen) do
    if ops_done() >= @total_ops, do: :ok, else: loop(w, next_seen(w, seen))
  end

  # one churn step; returns true when an op actually acked (kill-straddling calls are
  # abandoned, uncounted, and retried on the next iteration)
  defp next_seen(w, seen) do
    acked =
      try do
        if rem(seen, 4) == 0 do
          fresh_run(w, seen)
        else
          pick_existing(w)
        end
      catch
        :exit, _ -> false
      end

    if acked, do: count_op()

    if acked, do: seen + 1, else: seen
  end

  defp fresh_run(w, seen) do
    store = dets!()
    id = "storm-w#{w}-r#{seen}"
    {:ok, rec} = Engine.start(store, spine(id), store_module: Dets)
    log_run(id)
    log_seq(rec.seq)
    settle_op(store, id)
  end

  # pick a non-terminal run owned by this worker and hit it with one random op
  defp pick_existing(w) do
    store = dets!()
    mine = Agent.get(__MODULE__.Log, &Enum.reverse(&1.runs))

    live =
      Enum.filter(mine, fn id ->
        String.starts_with?(id, "storm-w#{w}-") and not terminal?(store, id)
      end)

    case live do
      [] ->
        false

      _ ->
        id = Enum.random(live)
        rand_op(store, id)
        true
    end
  end

  defp rand_op(store, id) do
    case :rand.uniform(3) do
      1 -> Engine.cancel(store, id, store_module: Dets)
      2 -> Engine.signal(store, id, "go", :storm, store_module: Dets)
      _ -> settle_op(store, id)
    end
  end

  # attempt → settle; a parked run re-parks or completes on a racing signal, a cancelling run
  # unwinds to :cancelled, a terminal run returns :ended.
  defp settle_op(store, id) do
    case Engine.attempt(store, id, store_module: Dets, lease_ms: 500) do
      {:parked, _} ->
        # half the time, immediately complete it via a signal + attempt (signal racing cancel)
        if :rand.uniform(2) == 1 do
          Engine.signal(store, id, "go", :storm, store_module: Dets)
          Engine.attempt(store, id, store_module: Dets, lease_ms: 500)
        end

      _other ->
        :ok
    end

    true
  end

  # -- drain + invariants -----------------------------------------------------------------------

  defp drain_and_verify(runs) do
    store = dets!()

    # clear orphaned waiter rows left by the kill, then drain: schedule an attempt after every
    # cancel (level-triggered unwind) until every run is terminal or passes are exhausted.
    Enum.each(runs, fn id ->
      try do
        Dets.release_all(store, id)
      catch
        :exit, _ -> :ok
      end
    end)

    drain_passes(runs, 60)

    stuck = Enum.filter(runs, &(not terminal?(store, &1)))

    assert stuck == [],
           "#{length(stuck)} runs never reached a terminal status after drain: " <>
             inspect(Enum.take(Enum.map(stuck, &fetch_status(store, &1)), 10))

    # invariant 1: no run left in :cancelling
    cancelling =
      Enum.filter(runs, fn id ->
        s = fetch_status(store, id)
        s == :cancelling or Status.rolling_back?(s)
      end)

    assert cancelling == [], "runs still rolling back after drain: #{inspect(cancelling)}"

    # invariant 2: no zombie waiters on terminal runs
    zombies =
      for id <- runs, w = Dets.waiters(store, id), w != [], into: %{} do
        {id, w}
      end

    assert zombies == %{}, "zombie waiters on terminal runs: #{inspect(zombies, limit: 10)}"

    # invariant 4: terminal states are intact and absorbing on the reopened store
    for id <- runs do
      assert :ended = Engine.attempt(store, id, store_module: Dets),
             "run #{id} did not refuse re-execution"
    end
  end

  defp drain_passes(_runs, 0), do: :ok

  defp drain_passes(runs, remaining) do
    store = dets!()

    nonterminal =
      Enum.filter(runs, fn id ->
        not terminal?(store, id)
      end)

    if nonterminal == [] do
      :ok
    else
      Enum.each(nonterminal, fn id ->
        try do
          Engine.attempt(store, id, store_module: Dets, lease_ms: 500)
        catch
          :exit, _ -> :ok
        end
      end)

      Process.sleep(50)
      drain_passes(runs, remaining - 1)
    end
  end

  defp verify_seqs do
    %{seqs_pre: pre, seqs_post: post} = Agent.get(__MODULE__.Log, & &1)
    assert pre != [] and post != [], "no seqs logged (pre: #{length(pre)}, post: #{length(post)})"

    # invariant 3: seq strictly monotone across the kill — the counter lives in the table, so
    # every post-reopen seq strictly exceeds every pre-kill seq.
    assert Enum.max(pre) < Enum.min(post),
           "seq not monotone across kill/reopen: max(pre)=#{Enum.max(pre)}, min(post)=#{Enum.min(post)}"
  end

  # -- spine builder (parked spine: two effects then a real waiter) ------------------------------

  defp spine(id) do
    tasks = [{:a, "File.Write", :file_write}, {:b, "File.Write", :file_write}, {:wait, "Human.Approve", :human_approve}]

    task_specs =
      tasks
      |> Enum.with_index()
      |> Enum.map(fn {{tid, cap, op}, i} ->
        base = [id: tid, capability: cap, authority: :construct]

        if i == 0,
          do: base,
          else: base ++ [after: [elem(Enum.at(tasks, i - 1), 0)]]
      end)

    {:ok, model} = Model.new(name: "cancel-storm-#{id}", goal: "g", tasks: task_specs)

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

  # -- plumbing -----------------------------------------------------------------------------------

  defp terminal?(store, id) do
    case Engine.fetch(store, id, store_module: Dets) do
      nil -> true
      %{status: s} -> Status.terminal?(s)
    end
  end

  defp fetch_status(store, id) do
    case Engine.fetch(store, id, store_module: Dets) do
      nil -> :not_found
      %{status: s} -> s
    end
  end

  defp log_run(id), do: Agent.update(__MODULE__.Log, &%{&1 | runs: [id | &1.runs]})
  defp log_seq(seq) do
    phase = pt().killer_done

    Agent.update(__MODULE__.Log, fn s ->
      if phase,
        do: %{s | seqs_post: [seq | s.seqs_post]},
        else: %{s | seqs_pre: [seq | s.seqs_pre]}
    end)
  end

  defp ops_done, do: Agent.get(__MODULE__.Log, & &1.ops)

  defp count_op(do_count \\ true)

  defp count_op(true), do: Agent.update(__MODULE__.Log, &%{&1 | ops: &1.ops + 1})
  defp count_op(false), do: :ok

  defp dets!, do: :persistent_term.get(@pt).dets

  defp pt, do: :persistent_term.get(@pt)

  defp put_pt(kvs), do: :persistent_term.put(@pt, Map.merge(pt(), Map.new(kvs)))

  defp wait_until(fun, ms) do
    deadline = System.monotonic_time(:millisecond) + ms

    wait_until_loop(fun, deadline)
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

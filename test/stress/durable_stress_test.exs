defmodule AshPPlan.Reactor.Durable.StressTest do
  @moduledoc """
  Concurrency stress for the durable engine (`lib/ash_pplan/reactor/durable/`) over the real
  `Store.Ets` GenServer, real `Engine`, real `Steps.Await/Poll/Dispatch` — no mocks, no test
  clock (the real clock; the race window is the subject under stress).

  Courts:
    1. 60 concurrent independent runs complete; measured throughput reported.
    2. 32 racing attempts at one run: exactly one winner, losers `:taken`; effects run once.
    3. 40-way signal + cancel + attempt storm on parked runs: every run reaches a terminal
       status, nothing hangs.
    4. Mixed-op store hammer: claim/release/signal/park/get/list concurrently; measured
       ops/sec; the store answers after the storm.
    5. `Steps.Await` under load: 100 concurrent parkers + signallers, each payload consumed
       exactly once, waiters released.
    6. `Steps.Poll` under load: conditions flip under concurrent pollers; waiter released.
    7. `Steps.Dispatch` fan-out: parents dispatch children, children complete under concurrent
       drains, every parent completes.
    8. Soak: 200 mixed runs (half parking on Await) complete; nothing left runnable.

  Numbers print to stdout: `mix test test/stress`.
  """

  use ExUnit.Case, async: false

  @moduletag :stress

  Code.require_file("lane_b_fixture.exs", Path.join(__DIR__, "../durable"))

  # A self-contained dispatch parent fixture (prep -> Dispatch child), the same shape as
  # AshPPlan.Test.DispatchFx, so the stress suite does not load the dispatch court file.
  defmodule StressDispatchFx do
    @moduledoc false
    alias AshPPlan.Reactor.Durable.Steps
    alias AshPPlan.Realization
    alias AshPPlan.Test.DurableFx
    alias AshPPlan.Workflow.Model

    defmodule Adapter do
      @moduledoc false
      @behaviour AshPPlan.Reactor.Adapter

      @impl true
      def id, do: :stress_dispatch_fx
      @impl true
      def available?, do: true
      @impl true
      def ops, do: [:order_admit, :workflow_dispatch]

      @impl true
      def step(op, options) do
        table = %{
          order_admit: {DurableFx.Effect, [effect: :parent_prep]},
          workflow_dispatch: {Steps.Dispatch, []}
        }

        AshPPlan.Reactor.Adapter.resolve(__MODULE__, table, op, options)
      end
    end

    def child_spec(_arguments, _context, child_effects),
      do: %{model: DurableFx.model(), bindings: DurableFx.bindings(child_effects)}

    def install_adapter! do
      previous = Application.get_env(:ash_pplan, :extra_adapters, %{})

      Application.put_env(
        :ash_pplan,
        :extra_adapters,
        Map.put(Map.new(previous), :stress_dispatch_fx, Adapter)
      )

      ExUnit.Callbacks.on_exit(fn -> Application.put_env(:ash_pplan, :extra_adapters, previous) end)
      :ok
    end

    def model do
      {:ok, m} =
        Model.new(
          name: :stress_dispatch_parent,
          goal: "stress_dispatch_parent_goal",
          methods: [%{id: :spine, task: :stress_dispatch_parent_goal, subtasks: [:prep, :child]}],
          tasks: [
            %{id: :prep, capability: "Order.Admit", depends_on: []},
            %{id: :child, capability: "Workflow.Dispatch", depends_on: [:prep]}
          ]
        )

      m
    end

    def bindings(parent_effects, child_effects) do
      %{
        prep: %Realization{
          capability: "Order.Admit",
          provider: :stress_dispatch_fx,
          binding: %{adapter: :stress_dispatch_fx, op: :order_admit},
          options: [effects: parent_effects]
        },
        child: %Realization{
          capability: "Workflow.Dispatch",
          provider: :stress_dispatch_fx,
          binding: %{adapter: :stress_dispatch_fx, op: :workflow_dispatch},
          options: [workflow: {__MODULE__, :child_spec, [child_effects]}, timeout: nil]
        }
      }
    end

    def attrs(id, parent_effects, child_effects) do
      %{
        id: id,
        model: model(),
        bindings: bindings(parent_effects, child_effects),
        inputs: %{input: %{}},
        context: %{},
        parent: nil
      }
    end
  end

  alias AshPPlan.Durable.LaneBFx
  alias AshPPlan.Reactor.Durable.{Engine, Key, Steps.Await, Steps.Poll, Testing}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Test.{DurableFx, Effects}

  @id_key AshPPlan.Reactor.context_key()

  setup do
    LaneBFx.install_adapter!()
    DurableFx.install_adapter!()
    StressDispatchFx.install_adapter!()
    {:ok, store} = Ets.start_link()
    {:ok, store: store}
  end

  # -- harness ---------------------------------------------------------------------------------

  defp timed(n, fun) do
    t0 = System.monotonic_time(:millisecond)
    result = fun.()
    ms = System.monotonic_time(:millisecond) - t0
    {result, ms, if(ms > 0, do: round(n / (ms / 1000)), else: n * 1000)}
  end

  defp report(label, ms, per_sec),
    do: IO.puts("[stress] #{label}: #{ms} ms total, #{per_sec}/sec")

  # Run `n` tasks of `fun.(i)` concurrently and await all, re-raising the first failure.
  defp concurrently(n, fun, timeout \\ 120_000) do
    1..n
    |> Enum.map(fn i -> Task.async(fn -> fun.(i) end) end)
    |> Enum.map(&Task.await(&1, timeout))
  end

  defp statuses(store, ids), do: Enum.map(ids, &Testing.status(store, &1))

  # Wait until `pred` holds or `ms` elapses.
  defp until(pred, ms \\ 30_000) do
    until(pred, ms, System.monotonic_time(:millisecond))
  end

  defp until(pred, budget, t0) do
    now = System.monotonic_time(:millisecond)

    cond do
      pred.() -> true
      now - t0 > budget -> false
      true -> (Process.sleep(5) && until(pred, budget, t0))
    end
  end

  defp await_ctx(store, id),
    do: %{
      durable: %{store: store, store_module: Ets, run_id: id, checkpoints: %{}},
      current_step: %{name: :stress},
      durable_step: :stress
    }

  # -- 1. concurrent independent runs ----------------------------------------------------------

  test "60 concurrent independent runs complete on the Ets store", %{store: store} do
    fx = :"stress_fx_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: fx)

    {outcomes, ms, per_sec} =
      timed(60, fn ->
        concurrently(60, fn i ->
          id = "thr-#{i}"
          {:ok, _} = Engine.start(store, LaneBFx.attrs(id, fx))
          {id, Engine.attempt(store, id)}
        end)
      end)

    report("60 concurrent linear runs", ms, per_sec)

    for {id, outcome} <- outcomes do
      assert {^id, {:completed, _}} = {id, outcome}, "run #{id}: #{inspect(outcome)}"
      assert %{status: :completed} = Engine.fetch(store, id)
      assert length(Engine.steps(store, id)) == 5
    end

    # exactly-once per step across all 60 runs
    for step <- [:observe, :select, :execute, :integrate, :verify] do
      n = Effects.count(fx, step)
      assert n == 60, "step #{step} ran #{n}x, want 60"
    end
  end

  # -- 2. racing attempts at one run ------------------------------------------------------------

  test "32 racing attempts at one run: exactly one winner, effects once", %{store: store} do
    fx = :"stress_fx_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: fx)
    runs = 10

    {all, ms, per_sec} =
      timed(runs * 32, fn ->
        for run <- 1..runs do
          id = "race-#{run}"
          {:ok, _} = Engine.start(store, LaneBFx.attrs(id, fx))
          {id, concurrently(32, fn _ -> Engine.attempt(store, id) end)}
        end
      end)

    report("#{runs * 32} racing attempts across #{runs} runs", ms, per_sec)

    for {id, outcomes} <- all do
      winners = Enum.count(outcomes, &match?({:completed, _}, &1))
      assert winners == 1, "#{id}: #{winners} winners in #{inspect(outcomes)}"

      assert Enum.all?(
               outcomes,
               &match?({:completed, _}, &1) or &1 in [:taken, :ended]
             ),
             "#{id}: #{inspect(outcomes)}"

      assert %{status: :completed, claimed_by: nil} = Engine.fetch(store, id)
    end

    for step <- [:observe, :select, :execute, :integrate, :verify] do
      n = Effects.count(fx, step)
      assert n == runs, "step #{step} ran #{n}x, want #{runs}"
    end
  end

  # Cancel parks a run at :cancelling; the unwind is level-triggered, so pump attempts until
  # the run settles (what Testing.drain does for a sequential court).
  defp pump_to_terminal(store, id, budget \\ 30_000) do
    until(fn ->
      case Testing.status(store, id) do
        s when s in [:completed, :cancelled, :failed] -> true
        nil -> true
        _ -> Engine.attempt(store, id) && false
      end
    end, budget)
  end

  # -- 3. signal + cancel + attempt storm -------------------------------------------------------

  test "signal+cancel+attempt storm on 20 parked runs ends terminal, nothing hangs", %{store: store} do
    fx = :"stress_fx_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: fx)

    ids =
      for i <- 1..20 do
        id = "storm-#{i}"
        {:ok, _} = Engine.start(store, LaneBFx.attrs(id, fx, kinds: %{integrate: :await}))
        assert {:parked, :waiting} = Engine.attempt(store, id)
        id
      end

    {_, ms, per_sec} =
      timed(20 * 40, fn ->
        concurrently(20, fn i ->
          id = "storm-#{i}"

          tasks =
            for _ <- 1..20, do: Task.async(fn -> Engine.signal(store, id, "go", :go) end)

          tasks =
            tasks ++ for _ <- 1..10, do: Task.async(fn -> Engine.cancel(store, id) end)

          tasks = tasks ++ for _ <- 1..10, do: Task.async(fn -> Engine.attempt(store, id) end)

          for t <- tasks, do: Task.await(t, 120_000)

          id
        end)
      end)

    report("800 mixed signal/cancel/attempt ops on 20 runs", ms, per_sec)

    for id <- ids do
      assert pump_to_terminal(store, id),
             "#{id} stuck at #{inspect(Testing.status(store, id))}"

      assert %{status: s, claimed_by: nil} = Engine.fetch(store, id)
      assert s in [:completed, :cancelled, :failed]
    end

    terminal = statuses(store, ids)
    IO.puts("[stress] storm terminal statuses: #{inspect(Enum.frequencies(terminal))}")

    # quiescent: level-triggered scheduler has nothing left to do
    assert Engine.runnable(store, DateTime.utc_now()) == []

    # completed runs hold a full 5-step tape (checkpoint ledger survived the storm intact)
    for {id, :completed} <- Enum.zip(ids, terminal) do
      assert length(Engine.steps(store, id)) == 5, "#{id} tape: #{inspect(Engine.steps(store, id))}"
    end
  end

  # -- 4. store GenServer contention ------------------------------------------------------------

  test "store contention: 16 processes x 2000 mixed ops, no deadlock", %{store: store} do
    ids =
      for i <- 1..8 do
        id = "hammer-#{i}"
        {:ok, _} = Engine.start(store, %{id: id, context: %{@id_key => %{subject: "s", workflow: :w}}})
        id
      end

    {_, ms, per_sec} =
      timed(16 * 2000, fn ->
        concurrently(16, fn worker ->
          for op <- 1..2000 do
            id = Enum.at(ids, rem(worker + op, 8))

            case rem(op, 7) do
              0 -> Ets.get_run(store, id)
              1 -> Ets.list_runs(store)
              2 -> Ets.claim(store, id, "w#{worker}", 30_000, DateTime.utc_now())
              3 -> Ets.release_claim(store, id, "w#{worker}")
              4 -> Ets.deliver_signal(store, id, "sig-#{worker}", op)
              5 -> Ets.park(store, id, "w#{worker}", :signal, nil, [])
              _ -> Ets.checkpoints(store, id)
            end
          end

          :ok
        end)
      end)

    report("32_000 mixed store ops (GenServer contention)", ms, per_sec)

    for id <- ids do
      run = Ets.get_run(store, id)
      assert %{status: :pending} = run, "hammered run moved to #{inspect(run.status)}"
      assert length(Ets.signals(store, id)) > 0
    end

    # the server answers promptly after the storm
    assert Ets.get_run(store, hd(ids)) != nil
  end

  # -- 5. Steps.Await under load ------------------------------------------------------------------

  test "Await under load: 100 concurrent parkers, exactly-once signal consumption", %{store: store} do
    n = 100

    {results, ms, per_sec} =
      timed(n, fn ->
        concurrently(n, fn i ->
          id = "await-#{i}"

          task =
            Task.async(fn ->
              Await.run(%{}, await_ctx(store, id), signal: "go", block_ms: 20_000)
            end)

          assert until(fn -> Ets.get_waiter(store, id, "go") != nil end, 10_000)
          {:ok, _} = Ets.deliver_signal(store, id, "go", {:payload, i})
          assert {:ok, {:payload, i}} = Task.await(task, 30_000)
          assert Ets.get_waiter(store, id, "go") == nil
          assert Ets.pending_signal(store, id, "go") == nil
          :ok
        end)
      end)

    assert results == List.duplicate(:ok, n)
    report("100 concurrent Await park+signal cycles", ms, per_sec)
  end

  # -- 6. Steps.Poll under load -------------------------------------------------------------------

  # named agent the poll condition flips through: :not_yet three times, then satisfied
  defmodule PollSeen do
    @moduledoc false
    def start, do: Agent.start_link(fn -> %{} end, name: __MODULE__)
    def check(id) do
      Agent.get_and_update(__MODULE__, fn m ->
        k = Map.get(m, id, 0)

        if k >= 3 do
          {{:ok, k}, Map.put(m, id, k)}
        else
          {:not_yet, Map.put(m, id, k + 1)}
        end
      end)
    end
  end

  def poll_check(_arguments, _context, id), do: PollSeen.check(id)

  test "Poll under load: 50 concurrent pollers flip under contention, waiter released", %{store: store} do
    n = 50
    {:ok, _} = PollSeen.start()

    {results, ms, per_sec} =
      timed(n, fn ->
        concurrently(n, fn i ->
          id = "poll-#{i}"

          task =
            Task.async(fn ->
              Stream.repeatedly(fn ->
                Poll.run(%{}, await_ctx(store, id), until: {__MODULE__, :poll_check, [id]}, every: 1)
              end)
              |> Enum.find(fn
                {:ok, _} -> true
                {:error, _} -> true
                _ -> false
              end)
            end)

          assert {:ok, checks} = Task.await(task, 60_000)
          assert checks >= 3
          assert Ets.get_waiter(store, id, "stress") == nil
          :ok
        end)
      end)

    assert results == List.duplicate(:ok, n)
    report("50 concurrent Poll cycles", ms, per_sec)
  end

  # -- 7. Dispatch fan-out ------------------------------------------------------------------------

  # the child id is derived from the dispatch step's name (its Reactor step IRI), as in the
  # Dispatch court
  defp child_step do
    AshPPlan.Workflow.Project.Reactor.step_iri(StressDispatchFx.model(), :child)
  end

  test "Dispatch under load: 30 parents each dispatch a child that completes concurrently", %{store: store} do
    parent_fx = :"pfx_#{System.unique_integer([:positive])}"
    child_fx = :"cfx_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: parent_fx)
    {:ok, _} = Effects.start_link(name: child_fx)
    n = 30

    ids =
      for i <- 1..n do
        id = "parent-#{i}"
        {:ok, _} = Engine.start(store, StressDispatchFx.attrs(id, parent_fx, child_fx))
        id
      end

    # the child id is derived from the dispatch step's name (its Reactor step IRI)
    child_of = fn parent_id -> Key.child_id(parent_id, child_step()) end

    {_, ms, per_sec} =
      timed(n, fn ->
        # children park on the DurableFx human_release gate; release each once it is parked,
        # then move on — the drain passes after this settle whatever the release woke
        releaser =
          Task.async(fn ->
            for id <- ids do
              child_id = child_of.(id)

              until(fn ->
                case Testing.status(store, child_id) do
                  :waiting ->
                    {:ok, _} = Engine.signal(store, child_id, DurableFx.signal_name(), :ok)
                    true

                  s ->
                    s == :completed
                end
              end, 20_000)

              :ok
            end
          end)

        # concurrent drains race the whole parent->child->parent graph to quiescence
        drains = concurrently(n, fn _ -> Testing.drain(store, max_rounds: 500) end)
        Task.await(releaser, 60_000)
        # final passes settle anything woken by the releases
        Testing.drain(store, max_rounds: 500)
        Testing.drain(store, max_rounds: 500)
        drains
      end)

    report("#{n} parents dispatching children under #{n}-way concurrent drains", ms, per_sec)

    for id <- ids do
      assert until(fn -> Testing.status(store, id) == :completed end),
             "parent #{id} at #{inspect(Testing.status(store, id))}"

      assert %{status: :completed} = Engine.fetch(store, child_of.(id)), "child of #{id}"
    end

    assert Effects.count(parent_fx, :parent_prep) == n
    assert Effects.count(child_fx, :admit) == n
    assert Effects.count(child_fx, :commit) == n
  end

  # -- 8. whole-engine soak -----------------------------------------------------------------------

  test "soak: 200 mixed runs complete with no deadlock or lost update", %{store: store} do
    fx = :"soak_fx_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: fx)

    {_, ms, per_sec} =
      timed(200, fn ->
        concurrently(50, fn w ->
          for j <- 0..3 do
            id = "soak-#{w}-#{j}"
            kinds = if rem(j, 2) == 0, do: %{}, else: %{integrate: :await}
            {:ok, _} = Engine.start(store, LaneBFx.attrs(id, fx, kinds: kinds))

            case Engine.attempt(store, id) do
              {:parked, :waiting} ->
                {:ok, _} = Engine.signal(store, id, "go", :go)
                assert {:completed, _} = Engine.attempt(store, id), "#{id} did not complete"

              {:completed, _} ->
                :ok

              other ->
                flunk("#{id}: unexpected #{inspect(other)}")
            end
          end

          :ok
        end)
      end)

    report("200 mixed runs (half parking on Await)", ms, per_sec)

    ids = for w <- 1..50, j <- 0..3, do: "soak-#{w}-#{j}"
    assert Enum.all?(statuses(store, ids), &(&1 == :completed))
    assert Engine.runnable(store, DateTime.utc_now()) == []

    # integrate is the Await step in half the runs (no Effects count there)
    for step <- [:observe, :select, :execute, :verify] do
      n = Effects.count(fx, step)
      assert n == 200, "step #{step} ran #{n}x, want 200"
    end

    assert Effects.count(fx, :integrate) == 100
  end
end

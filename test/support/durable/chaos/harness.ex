defmodule AshPPlan.Test.Chaos.Harness do
  @moduledoc """
  Executes one chaos scenario against the real durable engine (real `Store.Ets` behind the
  kill-capable `Chaos.Store`, real Reactor, real test `Clock`) and returns an observation map for
  `AshPPlan.Test.Chaos.Invariants`.

  Phases: (1) run the scenario's ops, taking a snapshot after each; (2) heal: disarm the kill plan,
  let the claim lease lapse, deliver every await signal never delivered, check the wake-up
  condition, drain to quiescence advancing to poll deadlines; (3) probe the terminal run: attempt,
  re-start, signal, clock jump, cancel and drain again, comparing against the pre-probe snapshot.
  """

  alias AshPPlan.Realization
  alias AshPPlan.Reactor.Durable.{Clock, Engine, Status, Testing}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Test.Chaos.{Adapter, Counter, Store}
  alias AshPPlan.Workflow.Model

  @lease_lapse_ms 3_600_000
  @run_id "chaos-run"

  @doc "Register the chaos adapter for the current test; restores on exit."
  @spec install!() :: :ok
  def install! do
    previous = Application.get_env(:ash_pplan, :extra_adapters, %{})

    Application.put_env(
      :ash_pplan,
      :extra_adapters,
      Map.put(Map.new(previous), :chaos_fx, Adapter)
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:ash_pplan, :extra_adapters, previous)
      Clock.reset()
    end)

    :ok
  end

  @doc "Number of property runs per invariant (env `ASH_PPLAN_CHAOS_RUNS`, default 20)."
  @spec runs() :: pos_integer()
  def runs do
    case Integer.parse(System.get_env("ASH_PPLAN_CHAOS_RUNS", "20")) do
      {n, _} when n > 0 -> n
      _ -> 20
    end
  end

  @spec run(map()) :: map()
  def run(scenario) do
    Clock.use_test_clock(~U[2026-01-01 00:00:00Z])
    {:ok, store} = Ets.start_link()
    {:ok, counter} = Counter.start_link()
    {:ok, _} = Store.start_plan()

    try do
      {:ok, _} = Engine.start(store, attrs(scenario, counter), store_module: Store)

      st = %{
        store: store,
        counter: counter,
        delivered: MapSet.new(),
        cancel: nil,
        trace: [],
        fired: 0
      }

      st = Enum.reduce(scenario.ops, st, &step/2)
      heal(scenario, st)
    after
      Store.stop_plan()
      if Process.alive?(counter), do: Agent.stop(counter)
    end
  end

  # -- model ---------------------------------------------------------------------------------

  def attrs(%{tasks: tasks}, counter) do
    indexed = Enum.with_index(tasks)
    ids = Enum.map(indexed, fn {_, i} -> id(i) end)

    model_tasks =
      for {t, i} <- indexed do
        %{
          id: id(i),
          capability: capability(t.kind),
          depends_on: Enum.map(t.deps, &id/1),
          authority: :construct
        }
      end

    {:ok, model} =
      Model.new(
        name: "chaos_workflow",
        goal: "chaos",
        tasks: model_tasks,
        methods: [%{id: :spine, task: :chaos, subtasks: ids}]
      )

    bindings =
      Map.new(indexed, fn {t, i} ->
        {id(i),
         %Realization{
           capability: capability(t.kind),
           provider: :chaos_fx,
           binding: %{adapter: :chaos_fx, op: t.kind},
           options: options(t, i, counter)
         }}
      end)

    %{
      id: @run_id,
      model: model,
      bindings: bindings,
      inputs: %{input: %{order: "chaos"}},
      context: %{},
      parent: nil
    }
  end

  defp options(%{kind: :count}, i, counter), do: [effects: counter, effect: {:t, i}]
  defp options(%{kind: :await}, i, _), do: [signal: signal_name(i)]

  defp options(%{kind: :poll, k: k}, i, counter),
    do: [until: {AshPPlan.Test.Chaos.Cond, :ready, [counter, i, k]}, every: 10]

  defp capability(:count), do: "Process.Count"
  defp capability(:await), do: "Event.Await"
  defp capability(:poll), do: "State.Await"

  @doc false
  def id(i), do: String.to_atom("t#{i}")
  @doc false
  def signal_name(i), do: "sig_#{i}"

  # -- ops -----------------------------------------------------------------------------------

  defp step(op, st), do: op |> apply_op(st) |> snap(op)

  defp apply_op(:attempt, st) do
    Engine.attempt(st.store, @run_id, store_module: Store)
    st
  end

  defp apply_op({:kill, phase, nth}, st) do
    {pid, ref} =
      spawn_monitor(fn ->
        Store.arm(phase, nth, self())
        Engine.attempt(st.store, @run_id, store_module: Store)
      end)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      10_000 -> Process.exit(pid, :kill)
    end

    fired = if Store.fired?(), do: 1, else: 0
    Store.disarm()
    %{st | fired: st.fired + fired}
  end

  defp apply_op({:signal, i}, st) do
    {:ok, _} = Engine.signal(st.store, @run_id, signal_name(i), :go, store_module: Store)
    %{st | delivered: MapSet.put(st.delivered, i)}
  end

  defp apply_op({:advance, ms}, st) do
    Clock.advance(ms)
    st
  end

  defp apply_op(:cancel, st) do
    case Engine.cancel(st.store, @run_id, store_module: Store) do
      {:ok, _} -> %{st | cancel: st.cancel || :accepted}
      {:error, _} -> st
    end
  end

  defp snap(st, op), do: %{st | trace: st.trace ++ [view(st, op)]}

  defp view(st, op) do
    %{
      op: op,
      status: Testing.status(st.store, @run_id),
      counts: Counter.effects(st.counter),
      cancel: st.cancel,
      tape: tape(st)
    }
  end

  defp tape(st), do: Testing.tape(st.store, @run_id)

  # -- heal & probe --------------------------------------------------------------------------

  defp heal(scenario, st) do
    Store.disarm()
    Clock.advance(@lease_lapse_ms)

    awaits = for {%{kind: :await}, i} <- Enum.with_index(scenario.tasks), do: i
    undelivered = Enum.reject(awaits, &MapSet.member?(st.delivered, &1))

    for i <- undelivered,
        do: {:ok, _} = Engine.signal(st.store, @run_id, signal_name(i), :go, store_module: Store)

    record = Engine.fetch(st.store, @run_id, store_module: Store)
    waiters = Store.waiters(st.store, @run_id)
    now = Clock.now()

    wake = %{
      status: record.status,
      runnable: Engine.runnable?(st.store, record, now, store_module: Store),
      poll_waiters: Enum.count(waiters, &(&1.kind == :poll))
    }

    drained =
      Testing.drain(st.store, store_module: Store, advance: :next_deadline, max_rounds: 300)

    final = Engine.fetch(st.store, @run_id, store_module: Store)
    before = freeze(st)

    probe(st)

    %{
      scenario: scenario,
      trace: st.trace,
      cancel: st.cancel,
      fired: st.fired,
      awaits: awaits,
      wake: wake,
      drain_rounds: length(drained),
      final_status: final.status,
      final_error: final.error,
      final_counts: Counter.effects(st.counter),
      final_tape: tape(st),
      before_probe: before,
      after_probe: freeze(st),
      terminal?: Status.terminal?(final.status)
    }
  end

  defp freeze(st) do
    r = Engine.fetch(st.store, @run_id, store_module: Store)
    steps = Engine.steps(st.store, @run_id, store_module: Store)

    %{
      status: r.status,
      result: r.result,
      error: r.error,
      outputs: Enum.map(steps, &{&1.label, &1.output}),
      step_keys: Enum.map(steps, & &1.step_key),
      counts: Counter.effects(st.counter)
    }
  end

  # Poke a (possibly terminal) run every way a late caller could.
  defp probe(st) do
    Engine.attempt(st.store, @run_id, store_module: Store)
    Engine.start(st.store, %{id: @run_id}, store_module: Store)
    Engine.signal(st.store, @run_id, "late", :x, store_module: Store)
    Clock.advance(@lease_lapse_ms)
    Engine.cancel(st.store, @run_id, store_module: Store)
    Testing.drain(st.store, store_module: Store, max_rounds: 5)
  end
end

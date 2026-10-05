defmodule AshPPlan.A2A.FacadeTest do
  @moduledoc """
  Court for `AshPPlan.A2A.Facade` — the A2A-provider surface ash_pplan serves
  natively (the in-tree consumer is `AshA2A.Providers.PPlan`).

  Zero mocks: real `AshPPlan.Reactor.Durable.Store.Ets` (ash_pplan's own test
  store), real counting-effect Reactor steps, the engine's own
  `Durable.Steps.Await` / `Durable.Steps.Poll` for the park hops. The adapter is
  the `:a2a_durability_fx` pattern the ash_a2a consumer court
  (`~/ash_a2a/test/ash_a2a_pplan_durability_test.exs`) uses, registered through
  `config :ash_pplan, :extra_adapters`.

  Acceptance: every `AshA2A.Providers.PPlan` call shape is served by the facade
  over ash_pplan's own stack — start-or-adopt by external key, signal-based
  resume, the nine-status mapping table, typed refusals on unknown keys.
  """

  use ExUnit.Case, async: false

  doctest AshPPlan.A2A.Facade

  alias AshPPlan.A2A.Facade
  alias AshPPlan.Reactor.Durable.Engine
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Test.Effects

  # -- real collaborators ------------------------------------------------------

  defmodule Effect do
    @moduledoc "Counting Reactor step; `options[:effect]` names the counter."
    use Reactor.Step

    @impl true
    def run(_arguments, _context, options) do
      case Effects.run(Keyword.fetch!(options, :effects), Keyword.fetch!(options, :effect)) do
        {:ok, n} -> {:ok, {Keyword.fetch!(options, :effect), n}}
        {:error, _} = err -> err
      end
    end
  end

  defmodule Adapter do
    @moduledoc """
    Test adapter: counting effects plus the engine's own Await/Poll durable
    steps. Realization options carry the per-test `:effects` agent name (data,
    survives a store round trip).
    """

    @behaviour AshPPlan.Reactor.Adapter

    alias AshPPlan.Reactor.Durable.Steps

    @impl true
    def id, do: :a2a_facade_fx

    @impl true
    def available?, do: true

    @impl true
    def ops, do: [:process_prepare, :process_finish, :event_await, :state_hold]

    @impl true
    def step(op, options) do
      table = %{
        process_prepare: {Effect, [effect: :prepare]},
        process_finish: {Effect, [effect: :finish]},
        event_await: {Steps.Await, [signal: "go", timeout: nil]},
        state_hold:
          {Steps.Poll,
           [
             until: {AshPPlan.Reactor.Adapters.Durable, :argument_until, [:ready]},
             every: 3_600_000
           ]}
      }

      AshPPlan.Reactor.Adapter.resolve(__MODULE__, table, op, options)
    end
  end

  # -- fixtures ----------------------------------------------------------------

  defp install_adapter! do
    previous = Application.get_env(:ash_pplan, :extra_adapters, %{})

    Application.put_env(
      :ash_pplan,
      :extra_adapters,
      Map.put(Map.new(previous), :a2a_facade_fx, Adapter)
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:ash_pplan, :extra_adapters, previous)
    end)

    :ok
  end

  defp model(name, tasks) do
    {:ok, m} = AshPPlan.Workflow.Model.new(name: name, goal: name, tasks: tasks)
    m
  end

  defp simple_model,
    do:
      model("a2a_facade_simple", [
        [id: :prepare, capability: "Process.Prepare", depends_on: []],
        [id: :finish, capability: "Process.Finish", depends_on: [:prepare]]
      ])

  defp await_model,
    do:
      model("a2a_facade_await", [
        [id: :prepare, capability: "Process.Prepare", depends_on: []],
        [id: :await, capability: "Event.Await", depends_on: [:prepare]],
        [id: :finish, capability: "Process.Finish", depends_on: [:await]]
      ])

  defp poll_model,
    do:
      model("a2a_facade_poll", [
        [id: :prepare, capability: "Process.Prepare", depends_on: []],
        [id: :hold, capability: "State.Hold", depends_on: [:prepare]]
      ])

  defp bindings(effects) do
    ops = [
      {:prepare, "Process.Prepare"},
      {:finish, "Process.Finish"},
      {:await, "Event.Await"},
      {:hold, "State.Hold"}
    ]

    Map.new(ops, fn {task, cap} ->
      {task,
       %AshPPlan.Realization{
         capability: cap,
         provider: :a2a_facade_fx,
         binding: %{adapter: :a2a_facade_fx, op: AshPPlan.Realization.op_for(cap)},
         options: [effects: effects]
       }}
    end)
  end

  setup do
    install_adapter!()

    effects = :"a2a_facade_effects_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: effects)

    {:ok, store} = Ets.start_link([])

    %{store: store, fx: effects}
  end

  # -- (1) start-or-adopt: idempotent by external key ---------------------------

  test "start_or_adopt/5 completes a simple run through the real engine", %{store: store, fx: fx} do
    opts = [store: store, store_module: Ets]

    assert {:ok, :completed, {:finish, 1}} =
             Facade.start_or_adopt(store, "facade-simple-1", simple_model(), bindings(fx), opts)

    assert %{prepare: 1, finish: 1} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}
  end

  test "re-dispatch of the same key adopts the run: no tape growth, no re-execution", %{
    store: store,
    fx: fx
  } do
    opts = [store: store, store_module: Ets]
    key = "facade-idem-1"

    assert {:ok, :completed, result} = Facade.start_or_adopt(store, key, simple_model(), bindings(fx), opts)

    tape0 = Engine.steps(store, key, store_module: Ets)

    assert {:ok, :completed, ^result} =
             Facade.start_or_adopt(store, key, simple_model(), bindings(fx), opts)

    tape1 = Engine.steps(store, key, store_module: Ets)
    assert length(tape1) == length(tape0)
    assert Enum.map(tape1, & &1.step_key) == Enum.map(tape0, & &1.step_key)

    assert %{prepare: 1, finish: 1} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}
  end

  # -- (2) park on Await -> :input_required; signal-based resume ----------------

  test "await park reports :input_required with waiter names; resume delivers one signal and completes",
       %{store: store, fx: fx} do
    opts = [store: store, store_module: Ets]
    key = "facade-await-1"

    assert {:ok, :input_required, ["go"]} =
             Facade.start_or_adopt(store, key, await_model(), bindings(fx), opts)

    assert {:ok, :input_required,
            %{run_status: :waiting, waiters: ["go"], version: v_parked, error: nil}} =
             Facade.status(store, key, opts)

    assert {:ok, :completed, _result} = Facade.resume(store, key, %{answer: 42}, opts)

    # exactly one signal delivered, consumed exactly once
    assert [%{name: "go", consumed_at: consumed}] = Ets.signals(store, key)
    refute is_nil(consumed)

    # the payload reached the plan as the Await step's output (finish ran once, prepare never re-ran)
    assert %{prepare: 1, finish: 1} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}

    assert {:ok, :completed, %{run_status: :completed, version: v_done, waiters: []}} =
             Facade.status(store, key, opts)

    assert v_done > v_parked
  end

  test "second resume on the terminal run returns the sealed state and moves nothing", %{
    store: store,
    fx: fx
  } do
    opts = [store: store, store_module: Ets]
    key = "facade-await-2"

    assert {:ok, :input_required, _} = Facade.start_or_adopt(store, key, await_model(), bindings(fx), opts)
    assert {:ok, :completed, result} = Facade.resume(store, key, 1, opts)
    assert {:ok, :completed, %{version: v}} = Facade.status(store, key, opts)

    assert {:ok, :completed, ^result} = Facade.resume(store, key, 2, opts)
    assert {:ok, :completed, %{version: ^v}} = Facade.status(store, key, opts)

    assert %{prepare: 1, finish: 1} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}
  end

  # -- (3) deadline-parked run is :working, never :input_required (falsifier 3) --

  test "poll park reports :working with nil detail; resume without a signal waiter refuses typed", %{
    store: store,
    fx: fx
  } do
    opts = [store: store, store_module: Ets]
    key = "facade-poll-1"

    assert {:ok, :working, nil} = Facade.start_or_adopt(store, key, poll_model(), bindings(fx), opts)

    assert {:ok, :working, %{run_status: :polling, version: v}} = Facade.status(store, key, opts)

    assert {:error, :no_signal_waiter} = Facade.resume(store, key, %{}, opts)

    assert {:ok, :working, %{run_status: :polling, version: ^v}} = Facade.status(store, key, opts)
  end

  # -- (4) explicit signal name opt wins; invalid one refuses typed --------------

  test "resume with an explicit :signal opt targets that name", %{store: store, fx: fx} do
    opts = [store: store, store_module: Ets]
    key = "facade-signal-opt-1"

    assert {:ok, :input_required, _} = Facade.start_or_adopt(store, key, await_model(), bindings(fx), opts)
    assert {:ok, :completed, _} = Facade.resume(store, key, :payload, Keyword.put(opts, :signal, "go"))
  end

  test "resume with an invalid signal name refuses typed and moves nothing", %{store: store, fx: fx} do
    opts = [store: store, store_module: Ets]
    key = "facade-signal-bad-1"

    assert {:ok, :input_required, _} = Facade.start_or_adopt(store, key, await_model(), bindings(fx), opts)

    assert {:error, {:invalid_signal, :not_a_string}} =
             Facade.resume(store, key, :payload, Keyword.put(opts, :signal, :not_a_string))

    assert {:ok, :input_required, %{run_status: :waiting}} = Facade.status(store, key, opts)
  end

  # -- (5) status mapping totality; typed refusals -------------------------------

  test "to_state/1 is total over the closed nine-status set" do
    all = AshPPlan.Reactor.Durable.Status.all()

    assert length(all) == 9

    for s <- all do
      assert {:ok, _state} = Facade.to_state(s)
    end

    assert Facade.to_state(:pending) == {:ok, :submitted}
    assert Facade.to_state(:waiting) == {:ok, :input_required}
    assert Facade.to_state(:polling) == {:ok, :working}
    assert Facade.to_state(:completed) == {:ok, :completed}
    assert Facade.to_state(:failed) == {:ok, :failed}
    assert Facade.to_state(:cancelled) == {:ok, :canceled}
  end

  test "to_state/1 on an unmapped status is a typed refusal, never a silent default" do
    assert {:error, {:unmapped_status, :someday_status}} = Facade.to_state(:someday_status)
  end

  test "status/ resume/ cancel/ attempt on an unknown key fail closed with {:error, :no_such_run}", %{
    store: store
  } do
    opts = [store: store, store_module: Ets]

    assert {:error, :no_such_run} = Facade.status(store, "facade-never-was", opts)
    assert {:error, :no_such_run} = Facade.resume(store, "facade-never-was", 1, opts)
    assert {:error, :no_such_run} = Facade.cancel(store, "facade-never-was", opts)
    assert {:error, :no_such_run} = Facade.attempt(store, "facade-never-was", opts)
  end

  # -- (6) cancel ----------------------------------------------------------------

  test "cancel/3 on an ended run returns the standing goal state, not an error", %{store: store, fx: fx} do
    opts = [store: store, store_module: Ets]
    key = "facade-cancel-ended-1"

    assert {:ok, :completed, result} =
             Facade.start_or_adopt(store, key, simple_model(), bindings(fx), opts)

    assert {:ok, :completed, ^result} = Facade.cancel(store, key, opts)
  end
end

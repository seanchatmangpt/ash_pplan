defmodule AshPPlan.A2A.Facade.StatusMappingTest do
  @moduledoc """
  Court for `AshPPlan.A2A.Facade`'s status/outcome mapping (Explore finding #5,
  the C26 adapter's open half): totality over the closed nine-status set, the
  engine-outcome table (typed refusal -> A2A `:rejected`, never `:working`),
  the sabotage twin (an ontology-added status fails the exact-table guard), and
  a real in-process refusal round-trip through the engine's policy gate.

  Zero mocks: real `AshPPlan.Reactor.Durable.Store.Ets`, real counting-effect
  steps via the facade court's registered adapter pattern, and the engine's own
  `PolicyDriver.admit/1` refusal path.
  """

  use ExUnit.Case, async: false

  doctest AshPPlan.A2A.Facade

  alias AshPPlan.A2A.Facade
  alias AshPPlan.Reactor.Durable.Status
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

  # Same adapter shape as `test/a2a_facade_test.exs` (simple two-step plan only;
  # the mapping court does not need park hops).
  defmodule Adapter do
    @moduledoc false

    @behaviour AshPPlan.Reactor.Adapter

    @impl true
    def id, do: :a2a_facade_mapping_fx

    @impl true
    def available?, do: true

    @impl true
    def ops, do: [:process_prepare, :process_finish]

    @impl true
    def step(op, options) do
      table = %{
        process_prepare: {Effect, [effect: :prepare]},
        process_finish: {Effect, [effect: :finish]}
      }

      AshPPlan.Reactor.Adapter.resolve(__MODULE__, table, op, options)
    end
  end

  # -- fixtures ----------------------------------------------------------------

  @a2a_states [:submitted, :working, :input_required, :completed, :failed, :canceled, :rejected]

  # The mapping table, stated here independently of the facade. If the ontology
  # adds a tenth run status, the exact-set assertion below fails and this court
  # forces the mapping to be revisited (the sabotage twin).
  @run_statuses ~w(pending waiting polling unwinding cancelling unwind_blocked completed failed cancelled)a

  @expected_mapping %{
    pending: :submitted,
    waiting: :input_required,
    polling: :working,
    unwinding: :working,
    cancelling: :working,
    unwind_blocked: :working,
    completed: :completed,
    failed: :failed,
    cancelled: :canceled
  }

  defp install_adapter! do
    previous = Application.get_env(:ash_pplan, :extra_adapters, %{})

    Application.put_env(
      :ash_pplan,
      :extra_adapters,
      Map.put(Map.new(previous), :a2a_facade_mapping_fx, Adapter)
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
      model("a2a_facade_mapping_simple", [
        [id: :prepare, capability: "Process.Prepare", depends_on: []],
        [id: :finish, capability: "Process.Finish", depends_on: [:prepare]]
      ])

  defp bindings(fx) do
    Map.new([{:prepare, "Process.Prepare"}, {:finish, "Process.Finish"}], fn {task, cap} ->
      {task,
       %AshPPlan.Realization{
         capability: cap,
         provider: :a2a_facade_mapping_fx,
         binding: %{adapter: :a2a_facade_mapping_fx, op: AshPPlan.Realization.op_for(cap)},
         options: [effects: fx]
       }}
    end)
  end

  setup do
    install_adapter!()

    fx = :"a2a_facade_mapping_effects_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: fx)

    {:ok, store} = Ets.start_link([])

    %{store: store, fx: fx}
  end

  # -- (1) totality: no silent fallthrough, every mapped state in the A2A set ---

  test "to_state/1 is total over Status.all/0 and lands in the closed A2A state set" do
    all = Status.all()

    assert length(all) == 9

    for s <- all do
      assert {:ok, state} = Facade.to_state(s)
      assert state in @a2a_states
      refute state == :working and s in [:completed, :failed, :cancelled],
             "terminal run status #{inspect(s)} must never surface as :working"
    end
  end

  test "the mapping table matches the facade exactly (drift + sabotage twin)" do
    # If the ontology adds a status, Status.all() diverges from the court's
    # closed nine and this fails BEFORE the facade can silently default it.
    assert Status.all() |> Enum.sort() == Enum.sort(@run_statuses)

    for {run_status, a2a_state} <- @expected_mapping do
      assert Facade.to_state(run_status) == {:ok, a2a_state}
    end
  end

  test "an atom outside the closed status set refuses typed, never a default state" do
    assert {:error, {:unmapped_status, :someday_status}} = Facade.to_state(:someday_status)
    assert {:error, {:unmapped_status, :rejected}} = Facade.to_state(:rejected)
    assert {:error, {:unmapped_status, :auth_required}} = Facade.to_state(:auth_required)
  end

  test "the A2A-only states :rejected/:auth_required are NOT run statuses (closed negative)" do
    # :rejected is produced at the engine-OUTCOME layer (below), never as a run
    # status; :auth_required is UNSUPPORTED-capability on the ash_pplan side.
    refute :rejected in Status.all()
    refute :auth_required in Status.all()
  end

  # -- (2) engine outcomes: typed refusal -> :rejected, never :working ----------

  test "attempt/3 maps the engine's typed admission refusal to terminal :rejected", %{
    store: store,
    fx: fx
  } do
    opts = [store: store, store_module: Ets]
    key = "facade-mapping-rejected-1"

    assert {:ok, :completed, _} = Facade.start_or_adopt(store, key, simple_model(), bindings(fx), opts)

    # A non-driver `:policy` opt is refused by the engine's own gate BEFORE the
    # run is read: no claim, no effect, typed reason.
    assert {:ok, :rejected, {:inadmissible_policy, {:not_a_driver, :garbage_driver}}} =
             Facade.attempt(store, key, Keyword.put(opts, :policy, :garbage_driver))
  end

  test "the refusal left the sealed run untouched (no state movement, no effects)", %{
    store: store,
    fx: fx
  } do
    opts = [store: store, store_module: Ets]
    key = "facade-mapping-rejected-2"

    assert {:ok, :completed, _} = Facade.start_or_adopt(store, key, simple_model(), bindings(fx), opts)

    assert {:ok, :rejected, _} =
             Facade.attempt(store, key, Keyword.put(opts, :policy, :garbage_driver))

    assert {:ok, :completed, %{run_status: :completed}} = Facade.status(store, key, opts)
    assert %{prepare: 1, finish: 1} ==
             %{prepare: Effects.count(fx, :prepare), finish: Effects.count(fx, :finish)}
  end

  test ":rejected is terminal per the A2A state machine (matches Task terminal set)" do
    # Read the sibling's real state validation: :rejected is in Task's
    # terminal-state set (v1.0: refused at admission, never resumable). Guarded
    # by Code.ensure_loaded? so the court holds in envs without :ash_a2a.
    if Code.ensure_loaded?(AshA2A.Protocol.Task) do
      attrs = apply(AshA2A.Protocol.Task, :module_info, [:attributes])
      terminal = get_attr(attrs)

      assert :rejected in terminal
      refute :working in terminal
    end
  end

  defp get_attr(attributes) do
    case Keyword.fetch(attributes, :terminal_states) do
      {:ok, [value]} -> value
      :error -> []
    end
  end
end

defmodule AshPPlan.Reactor.Durable.DispatchDurabilityTest do
  @moduledoc """
  Lane T21 regression court for the a2a task-dispatch durability shape over the
  real `Engine` + `AshPPlan.Reactor.Durable.Store.Ets` — the same shape as
  ash_a2a's pplan dispatch durability court, in-repo so dispatch-path
  regressions surface in ash_pplan first.

  A dispatch parks on an Await after its prepare effect executed exactly once
  (the effect derives its external idempotency token from the wrapper's
  `context.durable_intent_token`), a follow-up delivery resumes the SAME run,
  and the finish effect executes exactly once — one run, one tape, effects
  counted exactly once across park + resume.

  Anti-vacuity falsifier (mutation, run manually): make
  `Checkpointed.run_inner` lib/ash_pplan/reactor/durable/checkpointed.ex skip
  `Run.record_intent` — the inner run is token-less, the effect step
  `Map.fetch!`s the token and raises, and the park + resume exactly-once
  contract fails loud here.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.Clock
  alias AshPPlan.Reactor.Durable.Engine
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Realization
  alias AshPPlan.Workflow.Model

  @adapter_id :t21_dispatch_fx

  defmodule Fx do
    @moduledoc "Real counting agent, token-keyed exactly-once law (a2a court idiom)."
    use Agent

    def start_link(name), do: Agent.start_link(fn -> %{} end, name: name)

    def run(server, {token, effect}) when is_binary(token) do
      Agent.get_and_update(server, fn s ->
        key = {:executed, token, effect}

        if Map.has_key?(s, key) do
          {{:ok, Map.fetch!(s, key)}, s}
        else
          n = Map.get(s, effect, 0) + 1

          s =
            s
            |> Map.put(key, n)
            |> Map.update(:tokens, %{effect => [token]}, fn m ->
              Map.update(m, effect, [token], &[token | &1])
            end)

          {{:ok, n}, s}
        end
      end)
    end

    def counts(server) do
      Agent.get(server, fn s ->
        s
        |> Map.drop([:tokens])
        |> Enum.reduce(%{}, fn {{:executed, _, effect}, _}, acc ->
          Map.update(acc, effect, 1, &(&1 + 1))
        end)
      end)
    end

    def tokens(server, effect), do: Agent.get(server, &get_in(&1, [:tokens, effect])) || []
  end

  defmodule Effect do
    @moduledoc "Counting step keyed on the wrapper's deterministic intent token."
    use Reactor.Step

    @impl true
    def run(_arguments, context, options) do
      token = Map.fetch!(context, :durable_intent_token)
      effects = Keyword.fetch!(options, :effects)
      effect = Keyword.fetch!(options, :effect)

      case Fx.run(effects, {token, effect}) do
        {:ok, n} -> {:ok, {effect, n}}
        {:error, _} = err -> err
      end
    end
  end

  defmodule Adapter do
    @moduledoc false
    @behaviour AshPPlan.Reactor.Adapter

    @impl true
    def id, do: :t21_dispatch_fx

    @impl true
    def available?, do: true

    @impl true
    def ops, do: [:process_prepare, :process_finish, :event_await]

    @impl true
    def step(op, options) do
      table = %{
        process_prepare: {Effect, [effect: :prepare]},
        process_finish: {Effect, [effect: :finish]},
        event_await: {AshPPlan.Reactor.Durable.Steps.Await, [signal: "go", timeout: nil]}
      }

      AshPPlan.Reactor.Adapter.resolve(__MODULE__, table, op, options)
    end
  end

  defp install_adapter! do
    previous = Application.get_env(:ash_pplan, :extra_adapters, %{})

    Application.put_env(
      :ash_pplan,
      :extra_adapters,
      Map.put(Map.new(previous), @adapter_id, Adapter)
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:ash_pplan, :extra_adapters, previous)
    end)

    :ok
  end

  defp attrs(id, fx) do
    {:ok, model} =
      Model.new(
        name: :t21_dispatch_await,
        goal: :dispatch_complete,
        tasks: [
          [id: :prepare, capability: "Process.Prepare", depends_on: []],
          [id: :await, capability: "Event.Await", depends_on: [:prepare]],
          [id: :finish, capability: "Process.Finish", depends_on: [:await]]
        ]
      )

    bindings =
      Map.new(model.tasks, fn t ->
        {t.id,
         %Realization{
           capability: t.capability,
           provider: @adapter_id,
           binding: %{adapter: @adapter_id, op: Realization.op_for(t.capability)},
           options: [effects: fx]
         }}
      end)

    %{id: id, model: model, bindings: bindings, inputs: %{input: %{}}, context: %{}}
  end

  setup do
    install_adapter!()
    Clock.use_test_clock(~U[2026-01-01 00:00:00Z])
    on_exit(&Clock.reset/0)

    fx = :"t21_fx_#{System.unique_integer([:positive])}"
    {:ok, _} = Fx.start_link(fx)

    {:ok, store} = Ets.start_link()
    %{store: store, fx: fx}
  end

  @tag :serial
  test "dispatch parks after exactly-one prepare; delivery resumes; finish exactly once; one run",
       %{store: store, fx: fx} do
    id = "t21-#{System.unique_integer([:positive])}"

    {:ok, _rec} = Engine.start(store, attrs(id, fx))
    assert {:parked, :waiting} = Engine.attempt(store, id)

    assert Fx.counts(fx) == %{prepare: 1}
    [cp] = Engine.steps(store, id)
    assert cp.name =~ ~r/step-prepare$/

    {:ok, _} = Engine.signal(store, id, "go", %{step: 2})
    assert {:completed, _} = Engine.attempt(store, id)

    assert %{prepare: 1, finish: 1} = Fx.counts(fx)
    assert length(Engine.steps(store, id)) == 3
    assert length(Ets.list_runs(store)) == 1

    run = Engine.fetch(store, id)
    assert run.status == :completed
    assert run.claimed_by == nil

    # idempotent re-dispatch: attempt on the terminal run is :ended, zero re-execution
    assert Engine.attempt(store, id) == :ended
    assert %{prepare: 1, finish: 1} = Fx.counts(fx)
  end

  @tag :serial
  test "intent token is deterministic in (run id, step): adopted across stores, not re-minted",
       %{store: store, fx: fx} do
    id = "t21-token-#{System.unique_integer([:positive])}"
    {:ok, _} = Engine.start(store, attrs(id, fx))
    assert {:parked, :waiting} = Engine.attempt(store, id)

    [token] = Fx.tokens(fx, :prepare)

    # pure function of (run id, step name): a fresh store, same run id, same
    # step re-executes under the SAME token (the adopt law across stores)
    {:ok, store2} = Ets.start_link()
    fx2 = :"t21_fx2_#{System.unique_integer([:positive])}"
    {:ok, _} = Fx.start_link(fx2)
    {:ok, _} = Engine.start(store2, attrs(id, fx2))
    assert {:parked, :waiting} = Engine.attempt(store2, id)

    [token2] = Fx.tokens(fx2, :prepare)
    assert token == token2

    # different run id, same step: different token (identity is per-run)
    id2 = id <> "-alt"
    {:ok, _} = Engine.start(store, attrs(id2, fx))
    assert {:parked, :waiting} = Engine.attempt(store, id2)
    token_alt = Fx.tokens(fx, :prepare) |> hd()
    assert token_alt != token
  end
end

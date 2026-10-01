defmodule AshPPlan.Test.ExtraFx do
  @moduledoc """
  Fixture for the `extra_*` durable courts: a real model, real counting steps, and per-task wait
  kinds with full options (`timeout`, `on_timeout`, `until`), all as data. The adapter binds the
  QualifiedFulfillment-free linear and diamond shapes used by the lane suites to the engine's own
  `Await`/`Poll`. No mocks: collaborators are the real Engine, `Store.Ets` and Reactor.

  Task kind is the realization option `kind:` (`:effect | :await | :poll`); `wait:` carries the
  wait options; `flag:` names the Agent a poll reads (satisfied when it holds `true`).
  """
  alias AshPPlan.Reactor.Durable.Steps.{Await, Poll}
  alias AshPPlan.Realization
  alias AshPPlan.Test.Effects
  alias AshPPlan.Workflow.Model

  defmodule Effect do
    @moduledoc "Counting effect step."
    use Reactor.Step

    @impl true
    def run(_arguments, _context, options) do
      effect = Keyword.fetch!(options, :effect)

      case Effects.run(Keyword.fetch!(options, :effects), effect) do
        {:ok, n} -> {:ok, {effect, n}}
        {:error, _} = err -> err
      end
    end
  end

  defmodule Adapter do
    @moduledoc "Test adapter for the extra courts."
    @behaviour AshPPlan.Reactor.Adapter

    @impl true
    def id, do: :extra_fx
    @impl true
    def available?, do: true
    @impl true
    def ops,
      do: [:work_observe, :work_select, :agent_execute, :work_integrate, :verification_check]

    @impl true
    def step(op, options) do
      {kind, options} = Keyword.pop(options, :kind, :effect)
      {wait, options} = Keyword.pop(options, :wait, [])
      {flag, options} = Keyword.pop(options, :flag)

      impl =
        case kind do
          :effect -> {Effect, options}
          :await -> {Await, wait}
          :poll -> {Poll, [until: {AshPPlan.Test.ExtraFx, :flag_set, [flag]}] ++ wait}
        end

      if op in ops(),
        do: {:ok, impl},
        else: {:error, %{reason: :unsupported, adapter: :extra_fx}}
    end
  end

  @doc "Poll condition: satisfied once the named Agent holds true."
  def flag_set(_arguments, _context, flag),
    do: if(Agent.get(flag, & &1), do: {:ok, :done}, else: :not_yet)

  def install_adapter! do
    previous = Application.get_env(:ash_pplan, :extra_adapters, %{})

    Application.put_env(
      :ash_pplan,
      :extra_adapters,
      Map.put(Map.new(previous), :extra_fx, Adapter)
    )

    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:ash_pplan, :extra_adapters, previous) end)
    :ok
  end

  @doc "Diamond root -> {left, right} -> join."
  def model do
    {:ok, m} =
      Model.new(
        name: :extra_diamond,
        goal: :close_frontier,
        tasks: [
          [id: :root, capability: "Work.Observe", authority: :observe],
          [id: :left, capability: "Work.Select", after: [:root], authority: :observe],
          [id: :right, capability: "Work.Integrate", after: [:root], authority: :construct],
          [
            id: :join,
            capability: "Verification.Check",
            after: [:left, :right],
            authority: :observe
          ]
        ]
      )

    m
  end

  @doc "`extra` maps task id => keyword merged into the realization options (`kind:`, `wait:`, `flag:`)."
  def attrs(id, effects, extra \\ %{}) do
    model = model()

    bindings =
      Map.new(model.tasks, fn t ->
        op = Realization.op_for(t.capability)

        {t.id,
         %Realization{
           capability: t.capability,
           provider: :extra_fx,
           binding: %{adapter: :extra_fx, op: op},
           options: [effects: effects, effect: t.id] ++ Map.get(extra, t.id, [])
         }}
      end)

    %{
      id: id,
      model: model,
      bindings: bindings,
      inputs: %{frontier: [%{id: :a, status: :open, deps: []}]},
      context: %{},
      parent: nil
    }
  end
end

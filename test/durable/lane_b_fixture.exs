defmodule AshPPlan.Durable.LaneBFx do
  @moduledoc """
  Shared fixture of the engine/run/claim courts: a real model, real bindings, real counting
  steps. Step options are data (the `Effects` agent is referenced by registered name), so the
  model and bindings survive the store as data. No mocks.

  A task's step kind is chosen by the realization option `kind:`
  `:effect | :undo | :await | :crash`; `effect:` names the counter.

  Also carries the migration courts' renamed linear model (`renamed_model/0`) and the shared
  `until/2` poll used by the race courts.
  """
  alias AshPPlan.Realization
  alias AshPPlan.Reactor.Durable.Steps.Await
  alias AshPPlan.Test.Effects
  alias AshPPlan.Workflow.Model

  require ExUnit.Assertions

  defmodule Effect do
    @moduledoc false
    use Reactor.Step

    @impl true
    def run(_arguments, _context, options) do
      sleep = Keyword.get(options, :sleep, 0)
      if sleep > 0, do: Process.sleep(sleep)

      case Effects.run(Keyword.fetch!(options, :effects), Keyword.fetch!(options, :effect)) do
        {:ok, n} -> {:ok, {Keyword.fetch!(options, :effect), n}}
        {:error, _} = err -> err
      end
    end
  end

  defmodule UndoEffect do
    @moduledoc false
    use Reactor.Step

    @impl true
    defdelegate run(arguments, context, options), to: Effect

    @impl true
    def undo(_value, _arguments, _context, options) do
      Effects.record(Keyword.fetch!(options, :effects), {:undo, Keyword.fetch!(options, :effect)})
      :ok
    end
  end

  # Simulates a process crash: the first execution kills the attempt process (set under the
  # persistent term `{LaneBFx, :victim}`) and itself, before it can return or record.
  defmodule CrashOnce do
    @moduledoc false
    use Reactor.Step

    @impl true
    def run(arguments, context, options) do
      effects = Keyword.fetch!(options, :effects)
      effect = Keyword.fetch!(options, :effect)

      if Effects.count(effects, {:crash, effect}) == 0 and
           :persistent_term.get({AshPPlan.Durable.LaneBFx, :victim}, nil) do
        Effects.record(effects, {:crash, effect})
        Process.exit(:persistent_term.get({AshPPlan.Durable.LaneBFx, :victim}), :kill)
        Process.exit(self(), :kill)
      else
        Effect.run(arguments, context, options)
      end
    end
  end

  defmodule Adapter do
    @moduledoc false
    @behaviour AshPPlan.Reactor.Adapter

    @impl true
    def id, do: :lane_b_fx
    @impl true
    def available?, do: true
    @impl true
    def ops,
      do: [:work_observe, :work_select, :agent_execute, :work_integrate, :verification_check]

    @impl true
    def step(op, options) do
      {kind, options} = Keyword.pop(options, :kind, :effect)

      impl =
        case kind do
          :effect -> {Effect, options}
          :undo -> {UndoEffect, options}
          :crash -> {CrashOnce, options}
          :await -> {Await, [signal: Keyword.get(options, :signal, "go"), timeout: nil]}
        end

      if op in ops(),
        do: {:ok, impl},
        else: {:error, %{reason: :unsupported, adapter: :lane_b_fx}}
    end
  end

  @linear [
    observe: "Work.Observe",
    select: "Work.Select",
    execute: "Agent.Execute",
    integrate: "Work.Integrate",
    verify: "Verification.Check"
  ]

  def install_adapter! do
    previous = Application.get_env(:ash_pplan, :extra_adapters, %{})

    Application.put_env(
      :ash_pplan,
      :extra_adapters,
      Map.put(Map.new(previous), :lane_b_fx, Adapter)
    )

    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:ash_pplan, :extra_adapters, previous) end)
    :ok
  end

  def task_ids(:linear), do: Keyword.keys(@linear)
  def task_ids(:parallel), do: [:root, :left, :right, :join]

  @doc "Linear observe -> select -> execute -> integrate -> verify, or a root/left/right/join diamond."
  def model(shape \\ :linear)

  def model(:linear) do
    {:ok, m} = Model.new(AshPPlan.Examples.UltraCode.Steps.workflow())
    m
  end

  def model(:parallel) do
    {:ok, m} =
      Model.new(
        name: :lane_b_parallel,
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

  @doc "The linear model with `observe` renamed to `observe_frontier` (migration courts)."
  def renamed_model do
    old = model(:linear)

    tasks =
      Enum.map(old.tasks, fn t ->
        t = Map.from_struct(t)
        %{t | id: rename(t.id), depends_on: Enum.map(t.depends_on, &rename/1)}
      end)

    {:ok, m} = Model.new(name: old.name, goal: old.goal, tasks: tasks)
    m
  end

  defp rename(:observe), do: :observe_frontier
  defp rename(id), do: id

  @doc "Bindings for `model/1`; `kinds` maps task id => step kind (default `:effect`), `extra` per-task opts."
  def bindings(model, effects, kinds \\ %{}, extra \\ %{}) do
    Map.new(model.tasks, fn t ->
      op = Realization.op_for(t.capability)
      kind = Map.get(kinds, t.id, :effect)

      {t.id,
       %Realization{
         capability: t.capability,
         provider: :lane_b_fx,
         binding: %{adapter: :lane_b_fx, op: op},
         options: [effects: effects, effect: t.id, kind: kind] ++ Map.get(extra, t.id, [])
       }}
    end)
  end

  def attrs(id, effects, opts \\ []) do
    model = model(Keyword.get(opts, :shape, :linear))

    %{
      id: id,
      model: model,
      bindings:
        bindings(model, effects, Keyword.get(opts, :kinds, %{}), Keyword.get(opts, :extra, %{})),
      inputs: %{frontier: [%{id: :a, status: :open, deps: []}]},
      context: %{},
      parent: Keyword.get(opts, :parent)
    }
  end

  def counts(effects), do: Effects.all(effects)

  @doc "Poll `fun` every 10ms until truthy; flunks after `n` tries (default 500)."
  def until(fun, n \\ 500) do
    cond do
      fun.() -> :ok
      n == 0 -> ExUnit.Assertions.flunk("condition never held")
      true -> Process.sleep(10) && until(fun, n - 1)
    end
  end
end

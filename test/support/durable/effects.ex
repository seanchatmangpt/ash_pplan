defmodule AshPPlan.Test.Effects do
  @moduledoc """
  Effect-once counter for durable-engine courts.

  A named `Agent` outside every runner, store and attempt: it outlives any simulated crash, so a
  court can assert that each consequential effect ran exactly once across halt, kill and replay.
  Steps reference it by registered name (data, not a pid) so their options stay serialisable.
  """

  @default __MODULE__

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @default)
    Agent.start_link(fn -> %{counts: %{}, fail_after: %{}} end, name: name)
  end

  @doc "Record one execution of `effect`; returns the new count."
  @spec record(atom() | pid(), term()) :: pos_integer()
  def record(server \\ @default, effect) do
    Agent.get_and_update(server, fn s ->
      n = Map.get(s.counts, effect, 0) + 1
      {n, put_in(s.counts[effect], n)}
    end)
  end

  @spec count(atom() | pid(), term()) :: non_neg_integer()
  def count(server \\ @default, effect), do: Agent.get(server, &Map.get(&1.counts, effect, 0))

  @spec all(atom() | pid()) :: %{term() => pos_integer()}
  def all(server \\ @default), do: Agent.get(server, & &1.counts)

  @doc "Make `effect` fail once it has already run `n` times (the `n+1`th execution errors)."
  @spec fail_after(atom() | pid(), term(), non_neg_integer()) :: :ok
  def fail_after(server \\ @default, effect, n),
    do: Agent.update(server, &put_in(&1.fail_after[effect], n))

  @doc """
  Record `effect` unless it was armed with `fail_after/3` and has hit its limit.
  Returns `{:ok, count}` or `{:error, {:effect_failed, effect}}`.
  """
  @spec run(atom() | pid(), term()) :: {:ok, pos_integer()} | {:error, {:effect_failed, term()}}
  def run(server \\ @default, effect) do
    Agent.get_and_update(server, fn s ->
      n = Map.get(s.counts, effect, 0)

      case s.fail_after do
        %{^effect => limit} when n >= limit -> {{:error, {:effect_failed, effect}}, s}
        _ -> {{:ok, n + 1}, put_in(s.counts[effect], n + 1)}
      end
    end)
  end
end

defmodule AshPPlan.Test.DurableFx do
  @moduledoc """
  QualifiedFulfillment-shaped workflow for durable-engine courts, built from the generated model.

  The model keeps the generated tasks `admit_order -> authorize_payment -> await_human_release ->
  commit_shipment` (same capabilities, outcomes, properties and authority, so the subject shape is
  the generated one). Realizations bind to the test adapter `:durable_fx`: three effect steps that
  count into `AshPPlan.Test.Effects`, and the engine's own `Durable.Steps.Await` for the human
  release (signal `"human_release"`). Step options are data (the Effects agent is referenced by
  registered name), so the model and bindings survive a store round trip.
  """

  alias AshPPlan.Realization
  alias AshPPlan.Workflow.Model

  @keep [:admit_order, :authorize_payment, :await_human_release, :commit_shipment]
  @signal "human_release"

  defmodule Effect do
    @moduledoc "Counting effect step; `options[:effect]` names the counter."
    use Reactor.Step

    @impl true
    def run(_arguments, _context, options) do
      effects = Keyword.fetch!(options, :effects)
      effect = Keyword.fetch!(options, :effect)

      case AshPPlan.Test.Effects.run(effects, effect) do
        {:ok, n} -> {:ok, {effect, n}}
        {:error, _} = err -> err
      end
    end
  end

  defmodule Adapter do
    @moduledoc "Test adapter mapping the QF capabilities to counting steps and the durable Await."
    @behaviour AshPPlan.Reactor.Adapter

    alias AshPPlan.Reactor.Durable.Steps

    @impl true
    def id, do: :durable_fx
    @impl true
    def available?, do: true
    @impl true
    def ops, do: [:order_admit, :payment_authorize, :human_approve, :shipment_commit]

    @impl true
    def step(op, options) do
      table = %{
        order_admit: {Effect, [effect: :admit]},
        payment_authorize: {Effect, [effect: :authorize]},
        human_approve: {Steps.Await, [signal: "human_release", timeout: nil]},
        shipment_commit: {Effect, [effect: :commit]}
      }

      AshPPlan.Reactor.Adapter.resolve(__MODULE__, table, op, options)
    end
  end

  @spec signal_name() :: String.t()
  def signal_name, do: @signal

  @doc "Register the test adapter for the current test module; restores on exit."
  @spec install_adapter!() :: :ok
  def install_adapter! do
    previous = Application.get_env(:ash_pplan, :extra_adapters, %{})

    Application.put_env(
      :ash_pplan,
      :extra_adapters,
      Map.put(Map.new(previous), :durable_fx, Adapter)
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:ash_pplan, :extra_adapters, previous)
    end)

    :ok
  end

  @doc "The generated QualifiedFulfillment model reduced to the durable-relevant spine."
  @spec model() :: Model.t()
  def model do
    full = AshPPlan.Generated.Workflows.QualifiedFulfillment.model()

    tasks =
      full.tasks
      |> Enum.filter(&(&1.id in @keep))
      |> Enum.map(&Map.from_struct/1)
      |> Enum.map(fn t -> %{t | depends_on: Enum.filter(t.depends_on, &(&1 in @keep))} end)
      |> Enum.map(fn
        %{id: :authorize_payment} = t -> %{t | depends_on: [:admit_order]}
        %{id: :await_human_release} = t -> %{t | depends_on: [:authorize_payment]}
        t -> t
      end)

    {:ok, model} =
      Model.new(
        name: "qualified_fulfillment_durable_spine",
        goal: full.goal,
        tasks: tasks,
        methods: [
          %{id: :spine, task: String.to_atom(full.goal), subtasks: @keep}
        ]
      )

    model
  end

  @doc "Bindings for `model/0`: every task realized by the `:durable_fx` adapter."
  @spec bindings(atom()) :: %{atom() => Realization.t()}
  def bindings(effects \\ AshPPlan.Test.Effects) do
    ops = %{
      admit_order: {"Order.Admit", :order_admit},
      authorize_payment: {"Payment.Authorize", :payment_authorize},
      await_human_release: {"Human.Approve", :human_approve},
      commit_shipment: {"Shipment.Commit", :shipment_commit}
    }

    Map.new(ops, fn {task, {cap, op}} ->
      {task,
       %Realization{
         capability: cap,
         provider: :durable_fx,
         binding: %{adapter: :durable_fx, op: op},
         options: [effects: effects]
       }}
    end)
  end

  @doc "Run attrs for `Engine.start/2`."
  @spec attrs(String.t(), keyword()) :: map()
  def attrs(id, opts \\ []) do
    %{
      id: id,
      model: model(),
      bindings: bindings(Keyword.get(opts, :effects, AshPPlan.Test.Effects)),
      inputs: %{input: %{order: "order-7"}},
      context: %{},
      parent: nil
    }
  end
end

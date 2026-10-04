defmodule AshPPlan.Reactor.Adapters.Local do
  @moduledoc "Adapter for in-repo step modules (event/state/actuation/scheduling/durability/observation/A2A)."
  @behaviour AshPPlan.Reactor.Adapter

  alias AshPPlan.Reactor.Durable.Clock
  alias AshPPlan.Reactor.Steps

  @table %{
    event_await: {Steps.Await, [mode: :await]},
    state_await: {Steps.Await, [mode: :await]},
    state_observe: {Steps.Await, [mode: :observe]},
    actuation_command: {Steps.Command, []},
    actuation_actuate: {Steps.Actuate, []},
    distributed_propose: {Steps.Propose, []},
    observation_telemetry: {Steps.Telemetry, []},
    # A local wakeup is a clock-gated await: the step polls the injectable
    # `Durable.Clock` and halts (`:pending`) until the clock reaches the
    # `wake_at` argument, then succeeds. The pack ontology realizes
    # Scheduling.Wakeup on adapter "local", so the honest in-process binding is
    # halt-and-resume against the shared injectable clock -- no durable ledger
    # is required for the wakeup itself (a durable variant additionally exists
    # in Adapters.Durable as a deadline-parked Poll).
    scheduling_wakeup: {Steps.Await, [probe: {__MODULE__, :wake_due, [:wake_at]}]},
    # A local checkpoint validates and normalizes the `continuation` argument,
    # returning it as the step output. Persistence is the enclosing runtime's
    # job: in a durable run the engine checkpoints every step output to the
    # ledger, so this output IS the checkpoint; in plain Reactor it surfaces in
    # the step results. An absent continuation is a typed error, not a fake.
    durability_checkpoint: {Steps.Await, [probe: {__MODULE__, :continuation, [:continuation]}]}
  }

  @impl true
  def id, do: :local
  @impl true
  def available?, do: true
  @impl true
  def ops, do: Map.keys(@table)
  @impl true
  def step(op, options), do: AshPPlan.Reactor.Adapter.resolve(__MODULE__, @table, op, options)

  @doc """
  Wakeup probe: `:pending` until the (injectable) clock reaches `arguments[key]`,
  then `{:ok, at}`. A non-`DateTime` instant is a typed error.
  """
  @spec wake_due(map(), atom()) :: {:ok, DateTime.t()} | :pending | {:error, term()}
  def wake_due(arguments, key) do
    case Map.get(arguments, key) do
      %DateTime{} = at ->
        if DateTime.compare(Clock.now(), at) == :lt, do: :pending, else: {:ok, at}

      nil ->
        {:error, {:missing_argument, key}}

      other ->
        {:error, {:invalid_wakeup_instant, other}}
    end
  end

  @doc """
  Checkpoint probe: validates that a `continuation` argument is present and
  answers `{:ok, value}`; the value becomes the step output (the checkpoint).
  """
  @spec continuation(map(), atom()) :: {:ok, term()} | {:error, term()}
  def continuation(arguments, key) do
    case Map.get(arguments, key) do
      nil -> {:error, {:missing_argument, key}}
      value -> {:ok, value}
    end
  end
end

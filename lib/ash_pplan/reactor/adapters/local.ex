defmodule AshPPlan.Reactor.Adapters.Local do
  @moduledoc "Adapter for in-repo step modules (event/state/actuation/scheduling/durability/observation/A2A)."
  @behaviour AshPPlan.Reactor.Adapter

  alias AshPPlan.Reactor.Steps

  @table %{
    event_await: {Steps.Await, [mode: :await]},
    state_await: {Steps.Await, [mode: :await]},
    state_observe: {Steps.Await, [mode: :observe]},
    actuation_command: {Steps.Command, []},
    actuation_actuate: {Steps.Actuate, []},
    distributed_propose: {Steps.Propose, []},
    observation_telemetry: {Steps.Telemetry, []}
  }

  @impl true
  def id, do: :local
  @impl true
  def available?, do: true
  @impl true
  def ops, do: Map.keys(@table)
  @impl true
  def step(op, options), do: AshPPlan.Reactor.Adapter.resolve(__MODULE__, @table, op, options)
end

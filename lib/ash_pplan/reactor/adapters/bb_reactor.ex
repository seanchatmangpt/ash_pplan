defmodule AshPPlan.Reactor.Adapters.BbReactor do
  @moduledoc """
  Adapter for robot actuation and state/event awaiting via `bb_reactor`
  (`BB.Reactor.Step.Command`, `WaitForState`, `WaitForEvent`).

  `Actuator.Command` -> `:actuator_command`, `State.Await` -> `:state_await`,
  `Event.Await` -> `:event_await`. `available?/0` is false when `bb_reactor`
  is absent and `step/2` then returns a typed `:unsupported` error.
  """
  @behaviour AshPPlan.Reactor.Adapter

  @table %{
    actuator_command: {BB.Reactor.Step.Command, []},
    state_await: {BB.Reactor.Step.WaitForState, []},
    event_await: {BB.Reactor.Step.WaitForEvent, []}
  }

  @impl true
  def id, do: :bb_reactor
  @impl true
  def available?, do: Code.ensure_loaded?(BB.Reactor.Step.Command)
  @impl true
  def ops, do: Map.keys(@table)
  @impl true
  def step(op, options), do: AshPPlan.Reactor.Adapter.resolve(__MODULE__, @table, op, options)
end

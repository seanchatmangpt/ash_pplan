defmodule AshPPlan.Reactor.Adapters.Durable do
  @moduledoc """
  Adapter for the native durable engine (`AshPPlan.Reactor.Durable.*`).

  Operations: `human_approve`, `event_await` -> `Durable.Steps.Await` (park until a signal
  arrives), `state_await` -> `Durable.Steps.Poll` (re-check on an interval),
  `schedule_deferred` / `scheduling_deferred` -> `Poll` with a clock-reached `until`, and
  `workflow_dispatch` -> `Durable.Steps.Dispatch` (run a child workflow as its own durable run).

  Step options are data (ints, atoms, `{m, f, args}`). The defaults here are MFAs into this
  module: the signal a wait listens for is the step's own label, `state_await` is satisfied by a
  truthy `:ready` argument, and a deferred step is due once the clock reaches its `:not_before`
  argument (a `DateTime`; absent means due now). Realizations override `signal`, `until`, `every`
  and `timeout` through `stepOptions`. Nothing here grants DO authority.
  """
  @behaviour AshPPlan.Reactor.Adapter

  alias AshPPlan.Reactor.Durable.{Clock, Key}
  alias AshPPlan.Reactor.Durable.Steps

  @await [signal: {__MODULE__, :step_signal, []}]
  @state [until: {__MODULE__, :argument_until, [:ready]}, every: 1_000]
  @deferred [until: {__MODULE__, :clock_reached, [:not_before]}, every: 1_000]

  @table %{
    human_approve: {Steps.Await, @await},
    event_await: {Steps.Await, @await},
    state_await: {Steps.Poll, @state},
    schedule_deferred: {Steps.Poll, @deferred},
    scheduling_deferred: {Steps.Poll, @deferred},
    # A wakeup is the timed sibling of a deferred: park a poll waiter until the
    # (injectable) clock reaches the `wake_at` argument (absent means due now),
    # then resume. Same lawful parking machinery as `scheduling_deferred`; the
    # local adapter carries the in-process analog against the shared clock.
    scheduling_wakeup:
      {Steps.Poll, [until: {__MODULE__, :clock_reached, [:wake_at]}, every: 1_000]},
    workflow_dispatch: {Steps.Dispatch, []}
  }

  @impl true
  def id, do: :durable
  @impl true
  def available?, do: true
  @impl true
  def ops, do: Map.keys(@table)
  @impl true
  def step(op, options), do: AshPPlan.Reactor.Adapter.resolve(__MODULE__, @table, op, options)

  @doc "Default signal name: the label of the running step."
  @spec step_signal(map(), map()) :: String.t()
  def step_signal(_arguments, context), do: Key.label(context.current_step.name)

  @doc "Satisfied when `arguments[key]` is truthy."
  @spec argument_until(map(), map(), atom()) :: {:ok, term()} | :not_yet
  def argument_until(arguments, _context, key) do
    case Map.get(arguments, key) do
      v when v in [nil, false] -> :not_yet
      v -> {:ok, v}
    end
  end

  @doc "Satisfied once the (injectable) clock reaches `arguments[key]`; absent means due."
  @spec clock_reached(map(), map(), atom()) :: {:ok, DateTime.t()} | :not_yet
  def clock_reached(arguments, _context, key) do
    now = Clock.now()

    case Map.get(arguments, key) do
      nil -> {:ok, now}
      %DateTime{} = at -> if DateTime.compare(now, at) == :lt, do: :not_yet, else: {:ok, now}
    end
  end
end

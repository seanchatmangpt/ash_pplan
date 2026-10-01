defmodule AshPPlan.Reactor.Adapters.ReactorProcess do
  @moduledoc """
  Adapter for supervised-process operations via `reactor_process`.

  `reactor_process` is a dev/test-only vendored dependency, so `available?/0`
  is false when the module is absent and `step/2` then returns a typed
  `:unsupported` error instead of crashing. Pass `available?: false` in the
  options to simulate absence.
  """
  @behaviour AshPPlan.Reactor.Adapter

  @table %{
    process_start: {Reactor.Process.Step.StartChild, []},
    process_count: {Reactor.Process.Step.CountChildren, []},
    process_terminate: {Reactor.Process.Step.TerminateChild, []}
  }

  @impl true
  def id, do: :reactor_process
  @impl true
  def available?, do: Code.ensure_loaded?(Reactor.Process.Step.StartChild)
  @impl true
  def ops, do: Map.keys(@table)
  @impl true
  def step(op, options), do: AshPPlan.Reactor.Adapter.resolve(__MODULE__, @table, op, options)
end

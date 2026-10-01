defmodule AshPPlan.Reactor.Adapters.ReactorFile do
  @moduledoc "Adapter for filesystem operations via `reactor_file`."
  @behaviour AshPPlan.Reactor.Adapter

  @table %{
    file_read: {Reactor.File.Step.ReadFile, []},
    file_write: {Reactor.File.Step.WriteFile, []},
    file_copy: {Reactor.File.Step.Cp, []},
    file_delete: {Reactor.File.Step.Rm, []},
    file_mkdir: {Reactor.File.Step.MkdirP, []}
  }

  @impl true
  def id, do: :reactor_file
  @impl true
  def available?, do: Code.ensure_loaded?(Reactor.File.Step.WriteFile)
  @impl true
  def ops, do: Map.keys(@table)
  @impl true
  def step(op, options), do: AshPPlan.Reactor.Adapter.resolve(__MODULE__, @table, op, options)
end

defmodule AshPPlan.Providers.Process do
  @moduledoc """
  Supervised process realizations via reactor_process.

  Capabilities: #{inspect(~w(Process.Start Process.Count Process.Terminate))}. Realization modules live in
  `AshPPlan.Providers.Steps`. Never grants DO authority.
  """
  @behaviour AshPPlan.Provider

  alias AshPPlan.Providers.Steps.Common

  @capabilities ~w(Process.Start Process.Count Process.Terminate)
  @properties [:compensable]
  @evidence [:process_result]
  @table %{
    "Process.Start" => {Reactor.Process.Step.StartChild, []},
    "Process.Count" => {Reactor.Process.Step.CountChildren, []},
    "Process.Terminate" => {Reactor.Process.Step.TerminateChild, []}
  }

  @impl true
  def id, do: :process
  @impl true
  def capabilities, do: @capabilities
  @impl true
  def properties, do: @properties
  @impl true
  def evidence, do: @evidence
  @impl true
  def cost, do: 1

  @impl true
  def qualify(requirement, context),
    do: Common.qualify(requirement, context, @capabilities, @properties, @evidence)

  @impl true
  def realize(requirement, context) do
    with :ok <- qualify(requirement, context) do
      Common.realize(requirement, id(), @table)
    end
  end
end

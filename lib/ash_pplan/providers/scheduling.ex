defmodule AshPPlan.Providers.Scheduling do
  @moduledoc """
  AshOban wake-up descriptors; no job is inserted at construct time.

  Capabilities: #{inspect(~w(Scheduling.Wakeup))}. Realization modules live in
  `AshPPlan.Providers.Steps`. Never grants DO authority.
  """
  @behaviour AshPPlan.Provider

  alias AshPPlan.Providers.Steps
  alias AshPPlan.Providers.Steps.Common

  @capabilities ~w(Scheduling.Wakeup)
  @properties [:scheduled]
  @evidence [:wakeup_descriptor]
  @table %{
    "Scheduling.Wakeup" => {Steps.Wakeup, []}
  }

  @impl true
  def id, do: :scheduling
  @impl true
  def capabilities, do: @capabilities
  @impl true
  def properties, do: @properties
  @impl true
  def evidence, do: @evidence
  @impl true
  def cost, do: 2

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

defmodule AshPPlan.Providers.Observation do
  @moduledoc """
  Telemetry-emitting observation steps.

  Capabilities: #{inspect(~w(Observation.Telemetry))}. Realization modules live in
  `AshPPlan.Providers.Steps`. Never grants DO authority.
  """
  @behaviour AshPPlan.Provider

  alias AshPPlan.Providers.Steps
  alias AshPPlan.Providers.Steps.Common

  @capabilities ~w(Observation.Telemetry)
  @properties [:observable]
  @evidence [:telemetry]
  @table %{
    "Observation.Telemetry" => {Steps.Telemetry, []}
  }

  @impl true
  def id, do: :observation
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

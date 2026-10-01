defmodule AshPPlan.Providers.Durability do
  @moduledoc """
  Durable, resumable, checkpointed execution via AshPPlan.Continuation.

  Capabilities: #{inspect(~w(Durability.Checkpoint))}. Realization modules live in
  `AshPPlan.Providers.Steps`. Never grants DO authority.
  """
  @behaviour AshPPlan.Provider

  alias AshPPlan.Providers.Steps
  alias AshPPlan.Providers.Steps.Common

  @capabilities ~w(Durability.Checkpoint)
  @properties [:durable, :resumable, :checkpointed]
  @evidence [:continuation]
  @table %{
    "Durability.Checkpoint" => {Steps.Checkpoint, []}
  }

  @impl true
  def id, do: :durability
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

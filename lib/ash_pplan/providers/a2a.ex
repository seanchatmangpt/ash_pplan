defmodule AshPPlan.Providers.A2A do
  @moduledoc """
  Candidate-only wrapper of AshPPlan.SA2A.Provider (authority :none).

  Capabilities: #{inspect(~w(Distributed.Propose))}. Realization modules live in
  `AshPPlan.Providers.Steps`. Never grants DO authority.
  """
  @behaviour AshPPlan.Provider

  alias AshPPlan.Providers.Steps
  alias AshPPlan.Providers.Steps.Common

  @capabilities ~w(Distributed.Propose)
  @properties []
  @evidence [:policy_candidate]
  @table %{
    "Distributed.Propose" => {Steps.Propose, []}
  }

  @impl true
  def id, do: :a2a
  @impl true
  def capabilities, do: @capabilities
  @impl true
  def properties, do: @properties
  @impl true
  def evidence, do: @evidence
  @impl true
  def cost, do: 5

  @impl true
  def qualify(requirement, context),
    do: Common.qualify(requirement, context, @capabilities, @properties, @evidence, [:none])

  @impl true
  def realize(requirement, context) do
    with :ok <- qualify(requirement, context) do
      Common.realize(requirement, id(), @table)
    end
  end
end

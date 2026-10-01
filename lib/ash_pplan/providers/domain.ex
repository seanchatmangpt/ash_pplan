defmodule AshPPlan.Providers.Domain do
  @moduledoc """
  Ash.Reactor-style domain realizations: run Ash create/read/update/destroy/generic actions.

  Capabilities: #{inspect(~w(Domain.Create Domain.Read Domain.Update Domain.Destroy Domain.Action))}. Realization modules live in
  `AshPPlan.Providers.Steps`. Never grants DO authority.
  """
  @behaviour AshPPlan.Provider

  alias AshPPlan.Providers.Steps
  alias AshPPlan.Providers.Steps.Common

  @capabilities ~w(Domain.Create Domain.Read Domain.Update Domain.Destroy Domain.Action)
  @properties [:transactional, :policy_checked]
  @evidence [:ash_result]
  @table %{
    "Domain.Create" => {Steps.DomainAction, kind: :create},
    "Domain.Read" => {Steps.DomainAction, kind: :read},
    "Domain.Update" => {Steps.DomainAction, kind: :update},
    "Domain.Destroy" => {Steps.DomainAction, kind: :destroy},
    "Domain.Action" => {Steps.DomainAction, kind: :action}
  }

  @impl true
  def id, do: :domain
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

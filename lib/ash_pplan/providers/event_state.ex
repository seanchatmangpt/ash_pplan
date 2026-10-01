defmodule AshPPlan.Providers.EventState do
  @moduledoc """
  Generic, provider-polled event/state await/observe plus command and actuation-intent steps. Actuation constructs intents only.

  Capabilities: #{inspect(~w(Event.Await State.Await State.Observe Actuation.Command Actuation.Actuate))}. Realization modules live in
  `AshPPlan.Providers.Steps`. Never grants DO authority.
  """
  @behaviour AshPPlan.Provider

  alias AshPPlan.Providers.Steps
  alias AshPPlan.Providers.Steps.Common

  @capabilities ~w(Event.Await State.Await State.Observe Actuation.Command Actuation.Actuate)
  @properties [:pollable]
  @evidence [:observation]
  @table %{
    "Event.Await" => {Steps.Await, mode: :await},
    "State.Await" => {Steps.Await, mode: :await},
    "State.Observe" => {Steps.Await, mode: :observe},
    "Actuation.Command" => {Steps.Command, []},
    "Actuation.Actuate" => {Steps.Actuate, []}
  }

  @impl true
  def id, do: :event_state
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

defmodule AshPPlan.Reactor.Adapters.AshReactor do
  @moduledoc "Adapter for Ash domain-action operations (Ash.Reactor)."
  @behaviour AshPPlan.Reactor.Adapter

  alias AshPPlan.Reactor.Steps

  @table %{
    domain_create: {Steps.DomainAction, [kind: :create]},
    domain_read: {Steps.DomainAction, [kind: :read]},
    domain_update: {Steps.DomainAction, [kind: :update]},
    domain_destroy: {Steps.DomainAction, [kind: :destroy]},
    domain_action: {Steps.DomainAction, [kind: :action]}
  }

  @impl true
  def id, do: :ash_reactor
  @impl true
  def available?, do: Code.ensure_loaded?(Ash.Reactor)
  @impl true
  def ops, do: Map.keys(@table)
  @impl true
  def step(op, options), do: AshPPlan.Reactor.Adapter.resolve(__MODULE__, @table, op, options)
end

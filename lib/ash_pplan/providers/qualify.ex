defmodule AshPPlan.Providers.Qualify do
  @moduledoc """
  Self-contained qualification shared by generated providers.

  A provider qualifies for a requirement only when it declares the capability,
  every required execution property and every required evidence kind, and the
  requested authority never exceeds `:construct`. Availability is not
  authority: nothing here grants DO. This module names no Reactor
  implementation; realization is described by `AshPPlan.Realization` and only
  `AshPPlan.Reactor` binds it to steps.
  """

  @authorities [:none, :observe, :select, :plan, :construct]

  @doc "Authority ceiling list (`:construct` is the maximum)."
  @spec authorities() :: [atom()]
  def authorities, do: @authorities

  @doc "Qualify `requirement` against a provider's declared surface."
  @spec check(map(), map(), [String.t()], [atom()], [atom()], [atom()]) ::
          :ok | {:error, term()}
  def check(requirement, context, capabilities, properties, evidence, authorities \\ @authorities) do
    capability = Map.get(requirement, :capability)
    authority = Map.get(requirement, :authority) || Map.get(context, :authority)

    cond do
      capability not in capabilities ->
        {:error, {:unsupported_capability, capability}}

      (missing = Map.get(requirement, :properties, []) -- properties) != [] ->
        {:error, {:missing_properties, missing}}

      (missing = Map.get(requirement, :evidence, []) -- evidence) != [] ->
        {:error, {:missing_evidence, missing}}

      authority != nil and authority not in authorities ->
        {:error, {:authority_exceeds_ceiling, authority}}

      true ->
        :ok
    end
  end

  @doc "Build the realization of `capability` from a provider's binding table."
  @spec realize(map(), atom(), %{String.t() => {atom(), atom(), keyword()}}, [atom()]) ::
          {:ok, AshPPlan.Realization.t()} | {:error, term()}
  def realize(requirement, provider, table, properties \\ []) do
    capability = Map.get(requirement, :capability)

    case Map.fetch(table, capability) do
      {:ok, {adapter, op, base}} ->
        {:ok,
         %AshPPlan.Realization{
           capability: capability,
           provider: provider,
           binding: %{adapter: adapter, op: op},
           options: Keyword.merge(base, Map.get(requirement, :options, [])),
           properties: properties
         }}

      :error ->
        {:error, {:unsupported_capability, capability}}
    end
  end

  @doc """
  Typed UNSUPPORTED when a dev/test-only adapter is absent, else `:ok`.

  `adapter_module` is looked up by name only; absence never crashes.
  """
  @spec adapter_available(module()) :: :ok | {:error, {:unsupported, atom()}}
  def adapter_available(adapter_module) do
    if Code.ensure_loaded?(adapter_module) and
         function_exported?(adapter_module, :available?, 0) and adapter_module.available?() do
      :ok
    else
      {:error, {:unsupported, :reactor_process_unavailable}}
    end
  end
end

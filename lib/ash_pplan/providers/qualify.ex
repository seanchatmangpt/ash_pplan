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
  def check(requirement, context, capabilities, properties, evidence, authorities \\ @authorities)

  def check(requirement, context, capabilities, properties, evidence, authorities)
      when is_map(requirement) and is_map(context) and is_list(capabilities) and
             is_list(properties) and
             is_list(evidence) and is_list(authorities) do
    capability = Map.get(requirement, :capability)
    authority = Map.get(requirement, :authority) || Map.get(context, :authority)

    cond do
      capability not in capabilities ->
        {:error, {:unsupported_capability, capability}}

      (missing = List.wrap(Map.get(requirement, :properties, [])) -- properties) != [] ->
        {:error, {:missing_properties, missing}}

      (missing = List.wrap(Map.get(requirement, :evidence, [])) -- evidence) != [] ->
        {:error, {:missing_evidence, missing}}

      authority != nil and authority not in authorities ->
        {:error, {:authority_exceeds_ceiling, authority}}

      true ->
        :ok
    end
  end

  # Typed-refusal law: a garbage requirement or declared surface is a typed
  # rejection, never a BadMapError / Enumerable crash.
  def check(_requirement, _context, _capabilities, _properties, _evidence, _authorities) do
    {:error, :invalid_requirement}
  end

  @doc "Build the realization of `capability` from a provider's binding table."
  @spec realize(map(), atom(), %{String.t() => {atom(), atom(), keyword()}}, [atom()]) ::
          {:ok, AshPPlan.Realization.t()} | {:error, term()}
  def realize(requirement, provider, table, properties \\ [])

  def realize(requirement, provider, table, properties) when is_map(table) do
    capability = Map.get(requirement, :capability)

    case Map.fetch(table, capability) do
      {:ok, {adapter, op, base}}
      when is_atom(adapter) and is_atom(op) and is_list(base) ->
        requirement_options = List.wrap(Map.get(requirement, :options, []))

        cond do
          not Keyword.keyword?(base) ->
            {:error, {:invalid_binding_entry, {capability, base}}}

          Keyword.keyword?(requirement_options) ->
            {:ok,
             %AshPPlan.Realization{
               capability: capability,
               provider: provider,
               binding: %{adapter: adapter, op: op},
               options: Keyword.merge(base, requirement_options),
               properties: properties
             }}

          true ->
            {:error, {:invalid_options, requirement_options}}
        end

      {:ok, malformed} ->
        {:error, {:invalid_binding_entry, {capability, malformed}}}

      :error ->
        {:error, {:unsupported_capability, capability}}
    end
  end

  # Typed-refusal law: a non-map binding table is a typed refusal, never a
  # FunctionClauseError.
  def realize(_requirement, _provider, _table, _properties),
    do: {:error, {:invalid_binding_entry, :not_a_map}}

  @doc """
  Typed UNSUPPORTED when a dev/test-only adapter is absent, else `:ok`.

  `adapter_module` is looked up by name only; absence never crashes.
  """
  @spec adapter_available(module()) :: :ok | {:error, {:unsupported, atom()}}
  def adapter_available(adapter_module) when is_atom(adapter_module) do
    if Code.ensure_loaded?(adapter_module) and
         function_exported?(adapter_module, :available?, 0) and
         safe_available?(adapter_module) do
      :ok
    else
      {:error, {:unsupported, :reactor_process_unavailable}}
    end
  end

  # Typed-refusal law: a non-atom adapter name is typed unavailable, never a
  # Code.ensure_loaded? crash.
  def adapter_available(_adapter_module),
    do: {:error, {:unsupported, :reactor_process_unavailable}}

  # Typed-refusal law: a dev/test-only adapter that raises in available?/0 is
  # unavailable, never a crash of qualification.
  defp safe_available?(adapter_module) do
    adapter_module.available?()
  rescue
    _ -> false
  end
end

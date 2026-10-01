defmodule AshPPlan.Providers.Steps.Common do
  @moduledoc """
  Shared qualification and realization logic for the in-repo providers.

  A provider qualifies for a requirement only when it declares the capability,
  every required execution property and every required evidence kind, and the
  requested authority never exceeds `:construct`. Availability is not
  authority: nothing here grants DO.
  """

  @max_authority [:none, :observe, :select, :plan, :construct]

  @doc "Qualify `requirement` against a provider's declared surface."
  @spec qualify(map(), map(), [String.t()], [atom()], [atom()], [atom()]) ::
          :ok | {:error, term()}
  def qualify(
        requirement,
        context,
        capabilities,
        properties,
        evidence,
        authorities \\ @max_authority
      ) do
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

  @doc "Resolve a capability to `{step, base_options}` via `table`, merging requirement options."
  @spec realize(map(), atom(), %{String.t() => {module(), keyword()}}) ::
          {:ok, AshPPlan.Provider.realization()} | {:error, term()}
  def realize(requirement, provider, table) do
    capability = Map.get(requirement, :capability)

    case Map.fetch(table, capability) do
      {:ok, {step, base}} ->
        {:ok,
         %{
           step: step,
           options: Keyword.merge(base, Map.get(requirement, :options, [])),
           provider: provider
         }}

      :error ->
        {:error, {:unsupported_capability, capability}}
    end
  end
end

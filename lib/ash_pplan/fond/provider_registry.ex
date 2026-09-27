defmodule AshPPlan.FOND.ProviderRegistry do
  @moduledoc "Immutable, non-actuating provider selection for FOND policy supervision."

  @enforce_keys [:generation, :providers]
  defstruct generation: 0, providers: %{}

  def new(providers \\ []) do
    Enum.reduce_while(providers, {:ok, %__MODULE__{}}, fn provider, {:ok, registry} ->
      case put(registry, provider) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def put(%__MODULE__{} = registry, provider) when is_map(provider) do
    id = Map.get(provider, :id)
    semantics = MapSet.new(List.wrap(Map.get(provider, :semantics, [])))
    cost = Map.get(provider, :cost, 0)
    available = Map.get(provider, :available, true)

    cond do
      is_nil(id) -> {:error, %{reason: :provider_id_required}}
      Map.has_key?(registry.providers, id) -> {:error, %{reason: :duplicate_provider, provider_id: id}}
      not (is_integer(cost) and cost >= 0) -> {:error, %{reason: :invalid_provider_cost, provider_id: id}}
      not is_boolean(available) -> {:error, %{reason: :invalid_provider_availability, provider_id: id}}
      MapSet.size(semantics) == 0 -> {:error, %{reason: :provider_semantics_required, provider_id: id}}
      not MapSet.subset?(semantics, MapSet.new([:strong, :strong_cyclic])) ->
        {:error, %{reason: :invalid_provider_semantics, provider_id: id}}
      true ->
        normalized = %{id: id, semantics: semantics, cost: cost, available: available}
        {:ok, %{registry | providers: Map.put(registry.providers, id, normalized)}}
    end
  end

  def observe(%__MODULE__{generation: generation} = registry, expected, id, available)
      when is_boolean(available) do
    cond do
      expected != generation ->
        {:error, %{reason: :stale_provider_generation, expected: expected, actual: generation}}

      not Map.has_key?(registry.providers, id) ->
        {:error, %{reason: :unknown_provider, provider_id: id}}

      true ->
        providers = Map.update!(registry.providers, id, &Map.put(&1, :available, available))
        {:ok, %{registry | providers: providers, generation: generation + 1}}
    end
  end

  def select(%__MODULE__{} = registry, semantics) when semantics in [:strong, :strong_cyclic] do
    registry.providers
    |> Map.values()
    |> Enum.filter(&(&1.available and MapSet.member?(&1.semantics, semantics)))
    |> Enum.sort_by(&{&1.cost, :erlang.term_to_binary(&1.id)})
    |> case do
      [provider | _] ->
        {:ok, %{provider_id: provider.id, semantics: semantics, registry_generation: registry.generation}}
      [] ->
        {:error, %{reason: :no_available_provider, semantics: semantics}}
    end
  end

  def available?(%__MODULE__{} = registry, id) do
    match?(%{available: true}, Map.get(registry.providers, id))
  end
end

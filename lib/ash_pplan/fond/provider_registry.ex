defmodule AshPPlan.FOND.ProviderRegistry do
  @moduledoc "Tracks provider offers and availability for powerless FOND supervision."
  defstruct providers: %{}, generation: 0

  def new(offers \\ []) do
    Enum.reduce(offers, %__MODULE__{}, fn offer, registry ->
      put(registry, offer.provider, offer, :up)
    end)
  end

  def put(registry, provider, offer, health \\ :up) when health in [:up, :down, :unknown] do
    generation = registry.generation + 1
    entry = %{provider: provider, offer: offer, health: health, generation: generation}
    %{registry | providers: Map.put(registry.providers, provider, entry), generation: generation}
  end

  def health(registry, provider, health) when health in [:up, :down, :unknown] do
    case Map.fetch(registry.providers, provider) do
      {:ok, entry} ->
        generation = registry.generation + 1
        entry = %{entry | health: health, generation: generation}
        {:ok, %{registry | providers: Map.put(registry.providers, provider, entry), generation: generation}}
      :error -> {:error, {:unknown_provider, provider}}
    end
  end

  def available(registry) do
    registry.providers
    |> Map.values()
    |> Enum.filter(&(&1.health == :up))
    |> Enum.sort_by(&inspect(&1.provider))
    |> Enum.map(& &1.offer)
  end
end

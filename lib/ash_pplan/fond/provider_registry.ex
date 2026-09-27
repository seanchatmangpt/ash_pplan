defmodule AshPPlan.FOND.ProviderRegistry do
  @moduledoc "Pure deterministic provider routing state for FOND runtimes."
  @enforce_keys [:providers, :generation]
  defstruct providers: %{}, generation: 0

  def new(providers \\ []) do
    Enum.reduce(providers, %__MODULE__{}, fn p, r ->
      {:ok, next} = put(r, p)
      next
    end)
  end

  def put(%__MODULE__{} = r, %{id: id} = p) do
    p =
      p
      |> Map.put(:capabilities, MapSet.new(Map.get(p, :capabilities, [])))
      |> Map.put_new(:health, :up)
      |> Map.put_new(:cost, 0)

    if p.health in [:up, :down] and is_number(p.cost) do
      {:ok, %{r | providers: Map.put(r.providers, id, p), generation: r.generation + 1}}
    else
      {:error, %{reason: :invalid_provider, provider: id}}
    end
  end

  def put(%__MODULE__{}, p), do: {:error, %{reason: :missing_provider_id, provider: p}}

  def select(%__MODULE__{} = r, required \\ []) do
    required = MapSet.new(required)

    r.providers
    |> Map.values()
    |> Enum.filter(&(&1.health == :up and MapSet.subset?(required, &1.capabilities)))
    |> Enum.sort_by(&{&1.cost, &1.id})
    |> case do
      [p | _] -> {:ok, p, r.generation}
      [] -> {:error, %{reason: :no_provider, required: MapSet.to_list(required)}}
    end
  end

  def observe_health(%__MODULE__{} = r, id, health, generation) when health in [:up, :down] do
    cond do
      generation != r.generation ->
        {:error, %{reason: :stale_provider_generation, expected: generation, actual: r.generation}}

      not Map.has_key?(r.providers, id) ->
        {:error, %{reason: :unknown_provider, provider: id}}

      true ->
        providers = update_in(r.providers[id], &Map.put(&1, :health, health))
        {:ok, %{r | providers: providers, generation: r.generation + 1}}
    end
  end
end

defmodule AshPPlan.FOND.ProviderRegistry do
  @moduledoc """
  Pure provider registry for FOND supervision. Generations fence stale health
  observations. Selection is deterministic and grants no actuation authority.
  """
  @enforce_keys [:generation, :providers]
  defstruct generation: 0, providers: %{}
  @modes [:strong, :strong_cyclic]

  def new(providers \\ []) when is_list(providers) do
    Enum.reduce_while(providers, {:ok, %__MODULE__{}}, fn p, {:ok, r} ->
      case put(r, p) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end
  def new(value), do: {:error, %{reason: :invalid_provider_collection, value: value}}

  def put(%__MODULE__{} = r, p) when is_map(p) do
    with {:ok, p} <- normalize(p) do
      {:ok, %{r | generation: r.generation + 1, providers: Map.put(r.providers, p.id, p)}}
    end
  end
  def put(%__MODULE__{}, p), do: {:error, %{reason: :invalid_provider, provider: p}}

  def set_available(%__MODULE__{} = r, id, available, observed_generation)
      when is_boolean(available) and is_integer(observed_generation) do
    cond do
      observed_generation != r.generation ->
        {:error, %{reason: :stale_provider_generation, observed: observed_generation, current: r.generation}}
      not Map.has_key?(r.providers, id) ->
        {:error, %{reason: :unknown_provider, provider_id: id}}
      true ->
        providers = update_in(r.providers[id], &Map.put(&1, :available, available))
        {:ok, %{r | generation: r.generation + 1, providers: providers}}
    end
  end

  def candidates(%__MODULE__{} = r, mode) when mode in @modes do
    r.providers
    |> Map.values()
    |> Enum.filter(&(&1.available and mode in &1.semantics))
    |> Enum.sort_by(&{Map.get(&1, :cost, 0), &1.id})
  end

  def select(%__MODULE__{} = r, preferred \\ @modes) when is_list(preferred) do
    preferred
    |> Enum.filter(&(&1 in @modes))
    |> Enum.find_value(fn mode ->
      case candidates(r, mode) do
        [p | _] -> {:ok, %{provider: p, provider_id: p.id, semantics: mode, generation: r.generation}}
        [] -> nil
      end
    end)
    |> case do
      nil -> {:error, %{reason: :no_available_provider, preferred_semantics: preferred}}
      selection -> selection
    end
  end
  def select(%__MODULE__{}, preferred),
    do: {:error, %{reason: :invalid_semantics_preference, preferred_semantics: preferred}}

  defp normalize(p) do
    modes = Map.get(p, :semantics)
    cost = Map.get(p, :cost, 0)
    available = Map.get(p, :available, true)
    cond do
      not Map.has_key?(p, :id) -> {:error, %{reason: :missing_provider_id}}
      not is_list(modes) or Enum.any?(modes, &(&1 not in @modes)) ->
        {:error, %{reason: :invalid_provider_semantics, semantics: modes}}
      not is_boolean(available) -> {:error, %{reason: :invalid_provider_availability, value: available}}
      not is_number(cost) or cost < 0 -> {:error, %{reason: :invalid_provider_cost, cost: cost}}
      true -> {:ok, p |> Map.put(:semantics, Enum.uniq(modes)) |> Map.put(:available, available) |> Map.put(:cost, cost)}
    end
  end
end

defmodule AshPPlan.FOND.ProviderRegistry do
  @moduledoc "Immutable generation-fenced provider routing data. No provider is invoked here."
  defstruct generation: 0, providers: %{}

  def new(providers \\ []) when is_list(providers) do
    Enum.reduce_while(providers, {:ok, %{}}, fn p, {:ok, acc} ->
      cond do
        not is_map(p) or not Map.has_key?(p, :id) ->
          {:halt, {:error, %{reason: :invalid_provider, provider: p}}}
        Map.has_key?(acc, p.id) ->
          {:halt, {:error, %{reason: :duplicate_provider, provider: p.id}}}
        true ->
          p = p |> Map.put_new(:available, true) |> Map.put_new(:cost, 0)
                |> Map.update(:capabilities, MapSet.new(), &MapSet.new/1)
          {:cont, {:ok, Map.put(acc, p.id, p)}}
      end
    end)
    |> case do
      {:ok, indexed} -> {:ok, %__MODULE__{providers: indexed}}
      error -> error
    end
  end

  def observe(%__MODULE__{} = r, generation, id, available) when is_boolean(available) do
    cond do
      generation != r.generation ->
        {:error, %{reason: :stale_provider_generation, expected: r.generation, observed: generation}}
      not Map.has_key?(r.providers, id) ->
        {:error, %{reason: :unknown_provider, provider: id}}
      true ->
        providers = update_in(r.providers[id], &Map.put(&1, :available, available))
        {:ok, %{r | providers: providers, generation: r.generation + 1}}
    end
  end

  def select(%__MODULE__{} = r, required \\ MapSet.new()) do
    r.providers
    |> Map.values()
    |> Enum.filter(&Map.get(&1, :available, true))
    |> Enum.filter(&MapSet.subset?(required, Map.get(&1, :capabilities, MapSet.new())))
    |> Enum.sort_by(&{Map.get(&1, :cost, 0), &1.id})
    |> case do
      [winner | _] -> {:ok, winner}
      [] -> {:error, %{reason: :no_available_provider, generation: r.generation}}
    end
  end
end

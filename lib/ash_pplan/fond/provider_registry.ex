defmodule AshPPlan.FOND.ProviderRegistry do
  @moduledoc """
  Immutable provider-health registry for powerless FOND supervision.

  Providers advertise semantic capabilities only. Selection is deterministic by
  bounded cost and stable identity. Every health mutation advances a generation;
  callers can fence stale observations with the generation they previously read.
  """

  @enforce_keys [:providers, :generation]
  defstruct [:providers, :generation]

  @type provider :: %{
          required(:id) => term(),
          required(:capabilities) => MapSet.t(term()),
          required(:cost) => number(),
          required(:available) => boolean()
        }
  @type t :: %__MODULE__{providers: %{optional(term()) => provider()}, generation: non_neg_integer()}

  @spec new([map()]) :: {:ok, t()} | {:error, term()}
  def new(providers \\ []) when is_list(providers) do
    Enum.reduce_while(providers, {:ok, %{}}, fn provider, {:ok, acc} ->
      with {:ok, provider} <- normalize(provider),
           false <- Map.has_key?(acc, provider.id) do
        {:cont, {:ok, Map.put(acc, provider.id, provider)}}
      else
        true -> {:halt, {:error, {:duplicate_provider, provider.id}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, providers} -> {:ok, %__MODULE__{providers: providers, generation: 0}}
      error -> error
    end
  end

  def new(value), do: {:error, {:invalid_provider_registry, value}}

  @spec select(t(), [term()]) :: {:ok, provider(), non_neg_integer()} | {:error, term()}
  def select(%__MODULE__{} = registry, required \\ []) when is_list(required) do
    required = MapSet.new(required)

    registry.providers
    |> Map.values()
    |> Enum.filter(&(&1.available and MapSet.subset?(required, &1.capabilities)))
    |> Enum.sort_by(&{&1.cost, stable_identity(&1.id)})
    |> case do
      [provider | _] -> {:ok, provider, registry.generation}
      [] -> {:error, {:no_available_provider, required |> MapSet.to_list() |> Enum.sort()}}
    end
  end

  @spec observe(t(), non_neg_integer(), term(), boolean()) :: {:ok, t()} | {:error, term()}
  def observe(%__MODULE__{} = registry, generation, id, available)
      when is_boolean(available) do
    with :ok <- require_generation(registry, generation),
         {:ok, provider} <- fetch(registry, id) do
      providers = Map.put(registry.providers, id, %{provider | available: available})
      {:ok, %{registry | providers: providers, generation: generation + 1}}
    end
  end

  @spec put(t(), non_neg_integer(), map()) :: {:ok, t()} | {:error, term()}
  def put(%__MODULE__{} = registry, generation, provider) do
    with :ok <- require_generation(registry, generation),
         {:ok, provider} <- normalize(provider) do
      {:ok,
       %{
         registry
         | providers: Map.put(registry.providers, provider.id, provider),
           generation: generation + 1
       }}
    end
  end

  @spec remove(t(), non_neg_integer(), term()) :: {:ok, t()} | {:error, term()}
  def remove(%__MODULE__{} = registry, generation, id) do
    with :ok <- require_generation(registry, generation),
         {:ok, _provider} <- fetch(registry, id) do
      {:ok,
       %{
         registry
         | providers: Map.delete(registry.providers, id),
           generation: generation + 1
       }}
    end
  end

  defp normalize(%{id: id} = provider) do
    capabilities = provider |> Map.get(:capabilities, []) |> MapSet.new()
    cost = Map.get(provider, :cost, 0)
    available = Map.get(provider, :available, true)

    cond do
      not is_number(cost) -> {:error, {:invalid_provider_cost, id, cost}}
      not is_boolean(available) -> {:error, {:invalid_provider_availability, id, available}}
      true -> {:ok, %{id: id, capabilities: capabilities, cost: cost, available: available}}
    end
  end

  defp normalize(provider), do: {:error, {:invalid_provider, provider}}

  defp fetch(registry, id) do
    case Map.fetch(registry.providers, id) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, {:unknown_provider, id}}
    end
  end

  defp require_generation(%__MODULE__{generation: generation}, generation), do: :ok
  defp require_generation(%__MODULE__{generation: current}, observed),
    do: {:error, {:stale_provider_generation, observed, current}}

  defp stable_identity(id), do: :erlang.term_to_binary(id)
end

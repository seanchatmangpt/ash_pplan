defmodule AshPPlan.FOND.ProviderRegistry do
  @moduledoc """
  Pure provider catalog for FOND runtime selection.

  The registry owns no process and performs no actuation. It turns provider
  capabilities and health observations into deterministic routing decisions.
  Every mutation increments a generation so callers can fence stale observations.
  """

  defstruct providers: %{}, generation: 0

  @type provider_id :: term()
  @type provider :: %{
          required(:id) => provider_id(),
          optional(:capabilities) => MapSet.t(term()),
          optional(:cost) => number(),
          optional(:healthy?) => boolean(),
          optional(atom()) => term()
        }
  @type t :: %__MODULE__{
          providers: %{optional(provider_id()) => provider()},
          generation: non_neg_integer()
        }

  def new(providers \\ []) do
    Enum.reduce(providers, %__MODULE__{}, fn provider, registry ->
      case put(registry, provider) do
        {:ok, next} -> next
        {:error, reason} -> raise ArgumentError, "invalid provider: #{inspect(reason)}"
      end
    end)
  end

  def put(%__MODULE__{} = registry, %{id: id} = provider) do
    normalized =
      provider
      |> Map.put_new(:capabilities, MapSet.new())
      |> Map.update!(:capabilities, &MapSet.new/1)
      |> Map.put_new(:cost, 0)
      |> Map.put_new(:healthy?, true)

    {:ok,
     %{
       registry
       | providers: Map.put(registry.providers, id, normalized),
         generation: registry.generation + 1
     }}
  end

  def put(%__MODULE__{}, provider), do: {:error, {:invalid_provider, provider}}

  def remove(%__MODULE__{} = registry, id) do
    if Map.has_key?(registry.providers, id) do
      {:ok,
       %{
         registry
         | providers: Map.delete(registry.providers, id),
           generation: registry.generation + 1
       }}
    else
      {:error, {:unknown_provider, id}}
    end
  end

  def observe_health(
        %__MODULE__{generation: generation} = registry,
        expected_generation,
        id,
        healthy?
      )
      when is_boolean(healthy?) do
    cond do
      expected_generation != generation ->
        {:error, {:stale_generation, expected_generation, generation}}

      not Map.has_key?(registry.providers, id) ->
        {:error, {:unknown_provider, id}}

      true ->
        providers = Map.update!(registry.providers, id, &Map.put(&1, :healthy?, healthy?))
        {:ok, %{registry | providers: providers, generation: generation + 1}}
    end
  end

  def select(%__MODULE__{} = registry, required_capabilities \\ []) do
    required = MapSet.new(required_capabilities)

    registry.providers
    |> Map.values()
    |> Enum.filter(&Map.get(&1, :healthy?, true))
    |> Enum.filter(fn provider ->
      required
      |> MapSet.subset?(Map.get(provider, :capabilities, MapSet.new()) |> MapSet.new())
    end)
    |> Enum.sort_by(fn provider -> {Map.get(provider, :cost, 0), inspect(provider.id)} end)
    |> case do
      [provider | _] -> {:ok, provider, registry.generation}
      [] -> {:error, {:no_provider, required |> MapSet.to_list() |> Enum.sort()}}
    end
  end
end

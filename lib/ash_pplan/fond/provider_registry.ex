defmodule AshPPlan.FOND.ProviderRegistry do
  @moduledoc "Pure provider availability registry for FOND supervision."
  defstruct providers: %{}, generation: 0
  def new, do: %__MODULE__{}
  def put(%__MODULE__{} = registry, provider, status) when status in [:up, :down, :degraded] do
    %{registry | providers: Map.put(registry.providers, provider, status), generation: registry.generation + 1}
  end
  def status(%__MODULE__{} = registry, provider), do: Map.get(registry.providers, provider, :up)
  def available?(registry, provider), do: status(registry, provider) in [:up, :degraded]
end

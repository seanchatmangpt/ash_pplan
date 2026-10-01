defmodule AshPPlan.Realization do
  @moduledoc """
  A provider's description of how a capability is realized, independent of any
  Reactor extension. Only `AshPPlan.Reactor` turns a realization into Reactor
  steps; workflows and generated catalogs never name an implementation.
  """

  @enforce_keys [:capability, :provider]
  defstruct capability: nil, provider: nil, binding: nil, options: [], properties: []

  @type t :: %__MODULE__{
          capability: String.t(),
          provider: atom(),
          binding: module() | term(),
          options: keyword(),
          properties: [atom()]
        }

  @doc "Normalize the legacy `%{step:, options:, provider:}` realization map."
  @spec from_map(map(), String.t()) :: t()
  def from_map(%{provider: provider} = map, capability) do
    %__MODULE__{
      capability: capability,
      provider: provider,
      binding: Map.get(map, :step),
      options: Map.get(map, :options, []),
      properties: Map.get(map, :properties, [])
    }
  end
end

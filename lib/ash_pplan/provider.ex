defmodule AshPPlan.Provider do
  @moduledoc """
  The single provider contract: a qualified realization of capabilities.

  Providers describe how a capability is realized as an `AshPPlan.Realization`
  (adapter + operation binding); they never name a Reactor implementation.
  Only `AshPPlan.Reactor` turns a realization into a step. Provider selection
  never alters workflow identity, and availability is not authority.
  """

  alias AshPPlan.Capability

  @type requirement :: %{
          required(:capability) => Capability.id(),
          optional(:properties) => [atom()],
          optional(:evidence) => [atom()],
          optional(atom()) => term()
        }
  @type context :: map()
  @type realization :: AshPPlan.Realization.t()

  @doc "Stable provider id."
  @callback id() :: atom()
  @doc "Capability ids this provider can realize."
  @callback capabilities() :: [Capability.id()]
  @doc "Execution properties (durable, resumable, ...) the provider supports."
  @callback properties() :: [atom()]
  @doc "Evidence kinds the provider can emit."
  @callback evidence() :: [atom()]
  @doc "Cost used only to order qualified candidates."
  @callback cost() :: number()
  @doc "Qualify for a requirement in a context; `{:error, reason}` removes the candidate."
  @callback qualify(requirement(), context()) :: :ok | {:error, term()}
  @doc "Produce the implementation-neutral `AshPPlan.Realization`."
  @callback realize(requirement(), context()) :: {:ok, realization()} | {:error, term()}
end

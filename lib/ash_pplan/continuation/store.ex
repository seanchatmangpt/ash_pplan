defmodule AshPPlan.Continuation.Store do
  @moduledoc """
  Application persistence contract for `AshPPlan.Continuation` envelopes.

  A downstream Ash application can implement these callbacks with resource
  actions backed by its chosen data layer. The store owns persistence only; it
  does not gain permission to resume a process merely because it can load one.
  """

  alias AshPPlan.Continuation

  @callback put(Continuation.t(), map()) :: :ok | {:ok, term()} | {:error, term()}
  @callback fetch(String.t(), map()) :: {:ok, Continuation.t()} | {:error, term()}
  @callback delete(String.t(), map()) :: :ok | {:error, term()}
end

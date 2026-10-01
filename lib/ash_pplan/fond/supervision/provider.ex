defmodule AshPPlan.FOND.Supervision.Provider do
  @callback candidates(term(), term()) :: {:ok, list()} | {:error, term()}
  @callback id() :: term()
end

defmodule AshPPlan.FOND.Runtime.Dispatcher do
  alias AshPPlan.FOND.Runtime.Outcome

  def dispatch(e, input, opts \\ []) do
    try do
      e.provider.dispatch(input, e.metadata, opts) |> Outcome.classify()
    rescue
      error -> {:terminal, {:exception, error}}
    catch
      :exit, reason -> {:retryable, {:exit, reason}}
    end
  end
end

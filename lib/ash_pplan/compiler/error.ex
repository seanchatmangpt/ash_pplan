defmodule AshPPlan.Compiler.Error do
  @moduledoc false

  defexception [:reason, details: %{}]

  @impl true
  def message(%__MODULE__{reason: reason, details: details}) do
    "ash_pplan compiler refused #{reason}: #{inspect(details)}"
  end
end

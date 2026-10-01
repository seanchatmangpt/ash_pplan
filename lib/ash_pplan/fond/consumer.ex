defmodule AshPPlan.FOND.Consumer do
  @moduledoc "Provider-neutral dispatch boundary for powerless FOND runtime intents."
  @callback dispatch(map(), keyword()) :: {:ok, term()} | {:error, term()}

  def dispatch(intent, adapter, opts \\ [])
  def dispatch(%{policy: %{kind: :goal}} = intent, _adapter, _opts), do: {:ok, {:goal, intent}}

  def dispatch(%{policy: %{kind: :fond_action}} = intent, adapter, opts)
      when is_atom(adapter) and is_list(opts), do: adapter.dispatch(intent, opts)

  def dispatch(intent, _adapter, _opts), do: {:error, {:invalid_intent, intent}}
end

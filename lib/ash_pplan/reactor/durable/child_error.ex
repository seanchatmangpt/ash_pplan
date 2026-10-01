defmodule AshPPlan.Reactor.Durable.ChildError do
  @moduledoc """
  How a dispatched child's failure reaches the run that dispatched it.

  `run_id` names the child, `error` is the child's own error. A chain of dispatches nests one of
  these inside the next, so the outermost message reads down to the cause.

  Design derived from mbuhot/magma (MIT per its mix.exs).
  """
  defexception [:run_id, :error]

  @type t :: %__MODULE__{run_id: String.t(), error: term()}

  @impl true
  def message(%__MODULE__{run_id: run_id, error: error}),
    do: "child run #{run_id} failed: #{describe(error)}"

  defp describe(error) when is_exception(error), do: Exception.message(error)
  defp describe(error), do: inspect(error)
end

defmodule AshPPlan.Providers.Steps.Checkpoint do
  @moduledoc """
  Durable checkpoint step. Halts the Reactor so `AshPPlan.Continuation.capture/5`
  can persist it; when the resume context carries `resume: true` (passed to
  `AshPPlan.Continuation.resume/4`) the step completes.
  """
  use Reactor.Step

  @impl true
  def run(arguments, context, options) do
    if resumed?(context) do
      {:ok, %{checkpoint: Keyword.get(options, :name), resumed?: true, arguments: arguments}}
    else
      {:halt, %{checkpoint: Keyword.get(options, :name)}}
    end
  end

  defp resumed?(context) do
    Map.get(context, :resume) == true or
      (is_map(Map.get(context, :private)) and Map.get(context.private, :resume) == true)
  end
end

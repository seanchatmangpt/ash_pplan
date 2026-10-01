defmodule AshPPlan.Reactor.Steps.Wakeup do
  @moduledoc """
  Scheduling step: describes an AshOban wake-up (trigger or schedule) for
  `:resource`/`:trigger`. It reads the activation descriptor only; no job is
  inserted (`inserted?: false`).
  """
  use Reactor.Step

  @impl true
  def run(_arguments, _context, options) do
    resource = Keyword.fetch!(options, :resource)
    trigger = Keyword.fetch!(options, :trigger)

    with {:ok, descriptor} <- AshPPlan.Oban.fetch_activation(resource, trigger) do
      {:ok, %{wakeup: descriptor, inserted?: false}}
    end
  end
end

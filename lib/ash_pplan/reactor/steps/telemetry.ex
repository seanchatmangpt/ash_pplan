defmodule AshPPlan.Reactor.Steps.Telemetry do
  @moduledoc """
  Observation step: emits `[:ash_pplan, :observation, name]` telemetry with the
  step arguments as metadata and returns the observation.
  """
  use Reactor.Step

  @impl true
  def run(arguments, _context, options) do
    name = Keyword.get(options, :name, :observed)
    measurements = %{system_time: System.system_time()}
    :telemetry.execute([:ash_pplan, :observation, name], measurements, %{arguments: arguments})
    {:ok, %{observed: name, arguments: arguments}}
  end
end

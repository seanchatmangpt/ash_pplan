defmodule AshPPlan.Telemetry.Emit.Noop do
  @moduledoc """
  Default `AshPPlan.Telemetry.Emit` implementation — a no-op.

  Emission is inert until a broadcaster-backed impl is admitted. This keeps
  the wiring calls in existing modules zero-cost and side-effect free out of
  the box.
  """

  @behaviour AshPPlan.Telemetry.Emit

  @impl AshPPlan.Telemetry.Emit
  def emit(_event, _opts), do: :ok
end

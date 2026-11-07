defmodule AshPPlan.Telemetry.EmitTest do
  use ExUnit.Case, async: true

  alias AshPPlan.Telemetry.Emit.Noop
  alias AshPPlan.Telemetry.Event

  test "default Noop impl is inert and returns :ok" do
    event = %Event.RunStatusChanged{run_id: :r, from: :a, to: :b}
    assert Noop.emit(event, topic: :r) == :ok
    # no messages, no side effects — inert
    refute_receive _anything, 100
  end
end

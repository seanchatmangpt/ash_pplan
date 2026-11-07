defmodule AshPPlan.Telemetry.Emit do
  @moduledoc """
  Behaviour for emitting telemetry events — the emission seam that lets
  existing modules publish telemetry WITHOUT this lane editing them.

  ## Wiring points (coordinator integration, disclosed in the T2 receipt)

  One line each; `Emit.emit/2` is fire-and-forget and never raises:

      # lib/ash_pplan/reactor/durable/engine.ex — after a checkpoint commits:
      AshPPlan.Telemetry.Emit.emit(
        %AshPPlan.Telemetry.Event.CheckpointCommitted{run_id: run_id, store: store},
        topic: run_id
      )

      # lib/ash_pplan/execution_receipt.ex — after a receipt is stored/observed:
      AshPPlan.Telemetry.Emit.emit(
        %AshPPlan.Telemetry.Event.ReceiptObserved{run_id: run_id, receipt_id: id},
        topic: run_id
      )

  Analogous one-liners exist for `RunStatusChanged` (state_machine.ex
  transition), `HazardTripped` (sa2a/subject_guard.ex), and `LeaseExpired`
  (reactor/durable/unwind.ex). The default impl is a no-op, so the calls are
  inert until a broadcaster-backed impl is admitted.

  See Also: `AshPPlan.Telemetry.Event`, `AshPPlan.Telemetry.Emit.Noop`
  """

  @doc """
  Emits a typed event struct. `opts` must include `topic:`; returns `:ok`
  unconditionally (emission is advisory — never a failure path).
  """
  @callback emit(AshPPlan.Telemetry.Event.t(), keyword()) :: :ok
end

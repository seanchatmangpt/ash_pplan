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

  ## Emission-point map

  Which engine site SHOULD emit which event. Sites marked [LANE-A5/F2-BOUNDARY]
  are mid-repair by another lane — do NOT wire them from this lane; the map is
  the integration contract, each call site is a one-liner wired at
  coordinator integration.

  | Engine site                                        | Event type           | Constructor |
  |----------------------------------------------------|----------------------|-------------|
  | `reactor/durable/engine.ex` state transitions      | `run_status_changed` | `Emit.Event.run_status_changed/4` |
  | `reactor/durable/engine.ex` checkpoint commit      | `checkpoint_committed` | `Emit.Event.checkpoint_committed/3` |
  | `reactor/durable/health_gate.ex` refusal path      | `invariant_refused`  | `Emit.Event.invariant_refused/3` |
  | `reactor/durable/store/wal.ex` integrity errors [LANE-A5/F2-BOUNDARY] | `wal_integrity` | `Emit.Event.wal_integrity/3` |
  | lease grant site (`fond/policy_supervisor.ex`) [LANE-A5/F2-BOUNDARY] | `lease_granted` | `Emit.Event.lease_granted/2` |
  | lease release site (`fond/policy_supervisor.ex`) [LANE-A5/F2-BOUNDARY] | `lease_released` | `Emit.Event.lease_released/2` |
  | `reactor/durable/unwind.ex` lease reclaim          | `lease_expired`      | `Emit.Event.lease_expired/2` |
  | `execution_receipt.ex` receipt observed            | `receipt_observed`   | `Emit.Event.receipt_observed/3` |
  | hazard/policy guard trip (`sa2a/subject_guard.ex`) | `hazard_tripped`     | `Emit.Event.hazard_tripped/3` |

  See Also: `AshPPlan.Telemetry.Event`, `AshPPlan.Telemetry.Emit.Event`,
  `AshPPlan.Telemetry.Emit.Noop`, `AshPPlan.Telemetry.Emit.BufferingEmitter`
  """

  @doc """
  Emits a typed event struct. `opts` must include `topic:`; returns `:ok`
  unconditionally (emission is advisory — never a failure path).
  """
  @callback emit(AshPPlan.Telemetry.Event.t(), keyword()) :: :ok

  @default_impl AshPPlan.Telemetry.Emit.Noop

  @doc """
  Dispatches an event to the configured emitter implementation (Application
  env `:ash_pplan, :emit_impl`, default `AshPPlan.Telemetry.Emit.Noop`).
  Fire-and-forget: never raises; returns `:ok` unconditionally (emission is
  advisory — never a failure path).
  """
  @spec emit(AshPPlan.Telemetry.Emit.Event.t(), keyword()) :: :ok
  def emit(event, opts) do
    impl = Application.get_env(:ash_pplan, :emit_impl, @default_impl)
    _ = impl.emit(event, opts)
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end

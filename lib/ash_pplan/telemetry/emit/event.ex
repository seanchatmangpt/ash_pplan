defmodule AshPPlan.Telemetry.Emit.Event do
  @moduledoc """
  Additive event vocabulary + constructor helpers extending
  `AshPPlan.Telemetry.Event` — this module ADDS; it never edits the existing
  `@enforce_keys` structs, which remain the canonical vocabulary.

  New structs (durable-primitive emission points):

    * `#{LeaseGranted}` — a lane lease was granted to an owner.
    * `#{LeaseReleased}` — a lane lease was released by its owner.
    * `#{InvariantRefused}` — a health gate refused an actuation on an
      invariant violation.
    * `#{WalIntegrity}` — a WAL integrity error was detected.

  Constructors build the typed structs positionally with optional metadata:

      Emit.Event.run_status_changed(run_id, :running, :done)
      Emit.Event.lease_granted(lease_id, owner: owner)

  `type_of/1` covers BOTH vocabularies (delegates to
  `AshPPlan.Telemetry.Event.type_of/1` for the originals), so emitters can
  resolve a discriminator for any struct in either module.

  See Also: `AshPPlan.Telemetry.Event`, `AshPPlan.Telemetry.Emit`
  """

  defmodule LeaseGranted do
    @moduledoc "A lane lease was granted to an owner."
    @enforce_keys [:lease_id]
    defstruct [:lease_id, :owner, :granted_at, :meta]

    @type t :: %__MODULE__{
            lease_id: term(),
            owner: term() | nil,
            granted_at: DateTime.t() | nil,
            meta: map() | nil
          }
  end

  defmodule LeaseReleased do
    @moduledoc "A lane lease was released by its owner."
    @enforce_keys [:lease_id]
    defstruct [:lease_id, :owner, :released_at, :meta]

    @type t :: %__MODULE__{
            lease_id: term(),
            owner: term() | nil,
            released_at: DateTime.t() | nil,
            meta: map() | nil
          }
  end

  defmodule InvariantRefused do
    @moduledoc "A health gate refused an actuation on an invariant violation."
    @enforce_keys [:run_id, :invariant]
    defstruct [:run_id, :invariant, :detail, :meta]

    @type t :: %__MODULE__{
            run_id: term(),
            invariant: term(),
            detail: term() | nil,
            meta: map() | nil
          }
  end

  defmodule WalIntegrity do
    @moduledoc "A WAL integrity error was detected."
    @enforce_keys [:store]
    defstruct [:store, :error, :run_id, :meta]

    @type t :: %__MODULE__{
            store: term(),
            error: term() | nil,
            run_id: term() | nil,
            meta: map() | nil
          }
  end

  @typedoc "Any typed event struct in either vocabulary."
  @type t ::
          AshPPlan.Telemetry.Event.t()
          | LeaseGranted.t()
          | LeaseReleased.t()
          | InvariantRefused.t()
          | WalIntegrity.t()

  @typedoc "Event type discriminator (union of both vocabularies)."
  @type type ::
          AshPPlan.Telemetry.Event.type()
          | :lease_granted
          | :lease_released
          | :invariant_refused
          | :wal_integrity

  # ── constructors (original vocabulary — delegates to Event structs) ────

  @doc "Constructor for `AshPPlan.Telemetry.Event.CheckpointCommitted`."
  @spec checkpoint_committed(term(), term(), keyword()) ::
          AshPPlan.Telemetry.Event.CheckpointCommitted.t()
  def checkpoint_committed(run_id, store, opts \\ []) do
    %AshPPlan.Telemetry.Event.CheckpointCommitted{
      run_id: run_id,
      store: store,
      step_count: opts[:step_count],
      meta: opts[:meta]
    }
  end

  @doc "Constructor for `AshPPlan.Telemetry.Event.RunStatusChanged`."
  @spec run_status_changed(term(), term(), term(), keyword()) ::
          AshPPlan.Telemetry.Event.RunStatusChanged.t()
  def run_status_changed(run_id, from, to, opts \\ []) do
    %AshPPlan.Telemetry.Event.RunStatusChanged{
      run_id: run_id,
      from: from,
      to: to,
      meta: opts[:meta]
    }
  end

  @doc "Constructor for `AshPPlan.Telemetry.Event.HazardTripped`."
  @spec hazard_tripped(term(), term(), keyword()) ::
          AshPPlan.Telemetry.Event.HazardTripped.t()
  def hazard_tripped(run_id, hazard, opts \\ []) do
    %AshPPlan.Telemetry.Event.HazardTripped{
      run_id: run_id,
      hazard: hazard,
      detail: opts[:detail],
      meta: opts[:meta]
    }
  end

  @doc "Constructor for `AshPPlan.Telemetry.Event.LeaseExpired`."
  @spec lease_expired(term(), keyword()) :: AshPPlan.Telemetry.Event.LeaseExpired.t()
  def lease_expired(lease_id, opts \\ []) do
    %AshPPlan.Telemetry.Event.LeaseExpired{
      lease_id: lease_id,
      owner: opts[:owner],
      expired_at: opts[:expired_at],
      meta: opts[:meta]
    }
  end

  @doc "Constructor for `AshPPlan.Telemetry.Event.ReceiptObserved`."
  @spec receipt_observed(term(), term(), keyword()) ::
          AshPPlan.Telemetry.Event.ReceiptObserved.t()
  def receipt_observed(run_id, receipt_id, opts \\ []) do
    %AshPPlan.Telemetry.Event.ReceiptObserved{
      run_id: run_id,
      receipt_id: receipt_id,
      standing: opts[:standing],
      meta: opts[:meta]
    }
  end

  # ── constructors (extended vocabulary) ─────────────────────────────────

  @doc "Constructor for `#{LeaseGranted}`. Stamps `granted_at` unless given."
  @spec lease_granted(term(), keyword()) :: LeaseGranted.t()
  def lease_granted(lease_id, opts \\ []) do
    %LeaseGranted{
      lease_id: lease_id,
      owner: opts[:owner],
      granted_at: opts[:granted_at] || DateTime.utc_now(),
      meta: opts[:meta]
    }
  end

  @doc "Constructor for `#{LeaseReleased}`. Stamps `released_at` unless given."
  @spec lease_released(term(), keyword()) :: LeaseReleased.t()
  def lease_released(lease_id, opts \\ []) do
    %LeaseReleased{
      lease_id: lease_id,
      owner: opts[:owner],
      released_at: opts[:released_at] || DateTime.utc_now(),
      meta: opts[:meta]
    }
  end

  @doc "Constructor for `#{InvariantRefused}`."
  @spec invariant_refused(term(), term(), keyword()) :: InvariantRefused.t()
  def invariant_refused(run_id, invariant, opts \\ []) do
    %InvariantRefused{
      run_id: run_id,
      invariant: invariant,
      detail: opts[:detail],
      meta: opts[:meta]
    }
  end

  @doc "Constructor for `#{WalIntegrity}`."
  @spec wal_integrity(term(), term(), keyword()) :: WalIntegrity.t()
  def wal_integrity(store, error, opts \\ []) do
    %WalIntegrity{
      store: store,
      error: error,
      run_id: opts[:run_id],
      meta: opts[:meta]
    }
  end

  # ── discriminator covering both vocabularies ────────────────────────────

  @doc "Discriminator atom for any typed event struct in either vocabulary."
  @spec type_of(t()) :: type()
  def type_of(%AshPPlan.Telemetry.Event.CheckpointCommitted{} = e),
    do: AshPPlan.Telemetry.Event.type_of(e)

  def type_of(%AshPPlan.Telemetry.Event.RunStatusChanged{} = e),
    do: AshPPlan.Telemetry.Event.type_of(e)

  def type_of(%AshPPlan.Telemetry.Event.HazardTripped{} = e),
    do: AshPPlan.Telemetry.Event.type_of(e)

  def type_of(%AshPPlan.Telemetry.Event.LeaseExpired{} = e),
    do: AshPPlan.Telemetry.Event.type_of(e)

  def type_of(%AshPPlan.Telemetry.Event.ReceiptObserved{} = e),
    do: AshPPlan.Telemetry.Event.type_of(e)

  def type_of(%LeaseGranted{}), do: :lease_granted
  def type_of(%LeaseReleased{}), do: :lease_released
  def type_of(%InvariantRefused{}), do: :invariant_refused
  def type_of(%WalIntegrity{}), do: :wal_integrity

  @doc """
  Run id extracted from a typed event struct (`nil` when the event carries no
  run — lease events carry `lease_id`; `WalIntegrity` carries it optionally).
  """
  @spec run_id_of(t()) :: term() | nil
  def run_id_of(%AshPPlan.Telemetry.Event.LeaseExpired{}), do: nil
  def run_id_of(%LeaseGranted{}), do: nil
  def run_id_of(%LeaseReleased{}), do: nil
  def run_id_of(%WalIntegrity{run_id: run_id}), do: run_id
  def run_id_of(%{run_id: run_id}), do: run_id
  def run_id_of(_), do: nil
end

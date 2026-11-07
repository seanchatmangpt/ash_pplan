defmodule AshPPlan.Telemetry.Event do
  @moduledoc """
  Typed event vocabulary for the PubSub telemetry broadcaster.

  Every event is a struct with `@enforce_keys` on its identity fields. A struct
  is converted to a broadcast payload via `to_event/3`, which stamps the
  per-topic monotonic `seq` and the `emitted_at` wall-clock timestamp.

  Vocabulary:

    * `#{CheckpointCommitted}` — a durable checkpoint was committed for a run.
    * `#{RunStatusChanged}` — a run transitioned between status values.
    * `#{HazardTripped}` — a hazard/policy violation was detected.
    * `#{LeaseExpired}` — a lane lease expired and was reclaimed.
    * `#{ReceiptObserved}` — an execution receipt was observed.

  See Also: `AshPPlan.Telemetry.Broadcaster`
  """

  defmodule CheckpointCommitted do
    @moduledoc "A durable checkpoint was committed for a run."
    @enforce_keys [:run_id, :store]
    defstruct [:run_id, :store, :step_count, :meta]

    @type t :: %__MODULE__{
            run_id: term(),
            store: term(),
            step_count: non_neg_integer() | nil,
            meta: map() | nil
          }
  end

  defmodule RunStatusChanged do
    @moduledoc "A run transitioned between status values."
    @enforce_keys [:run_id, :from, :to]
    defstruct [:run_id, :from, :to, :meta]

    @type t :: %__MODULE__{
            run_id: term(),
            from: term(),
            to: term(),
            meta: map() | nil
          }
  end

  defmodule HazardTripped do
    @moduledoc "A hazard/policy violation was detected."
    @enforce_keys [:run_id, :hazard]
    defstruct [:run_id, :hazard, :detail, :meta]

    @type t :: %__MODULE__{
            run_id: term(),
            hazard: term(),
            detail: term() | nil,
            meta: map() | nil
          }
  end

  defmodule LeaseExpired do
    @moduledoc "A lane lease expired and was reclaimed."
    @enforce_keys [:lease_id]
    defstruct [:lease_id, :owner, :expired_at, :meta]

    @type t :: %__MODULE__{
            lease_id: term(),
            owner: term() | nil,
            expired_at: DateTime.t() | nil,
            meta: map() | nil
          }
  end

  defmodule ReceiptObserved do
    @moduledoc "An execution receipt was observed."
    @enforce_keys [:run_id, :receipt_id]
    defstruct [:run_id, :receipt_id, :standing, :meta]

    @type t :: %__MODULE__{
            run_id: term(),
            receipt_id: term(),
            standing: atom() | nil,
            meta: map() | nil
          }
  end

  @typedoc "Broadcast payload envelope."
  @type event :: %{
          required(:topic) => topic(),
          required(:type) => type(),
          required(:run_id) => term() | nil,
          required(:seq) => pos_integer(),
          required(:data) => struct(),
          required(:emitted_at) => DateTime.t()
        }

  @typedoc "Topic — a run id or a global channel atom."
  @type topic :: term()

  @typedoc "Event type discriminator."
  @type type ::
          :checkpoint_committed
          | :run_status_changed
          | :hazard_tripped
          | :lease_expired
          | :receipt_observed

  @typedoc "Any typed event struct in this vocabulary."
  @type t ::
          CheckpointCommitted.t()
          | RunStatusChanged.t()
          | HazardTripped.t()
          | LeaseExpired.t()
          | ReceiptObserved.t()

  @doc "Discriminator atom for a typed event struct."
  @spec type_of(t()) :: type()
  def type_of(%CheckpointCommitted{}), do: :checkpoint_committed
  def type_of(%RunStatusChanged{}), do: :run_status_changed
  def type_of(%HazardTripped{}), do: :hazard_tripped
  def type_of(%LeaseExpired{}), do: :lease_expired
  def type_of(%ReceiptObserved{}), do: :receipt_observed

  @doc """
  Run id extracted from a typed event struct (`nil` when the event carries no
  run — e.g. `#{LeaseExpired}` carries `lease_id` instead).
  """
  @spec run_id_of(t()) :: term() | nil
  def run_id_of(%{run_id: run_id}), do: run_id
  def run_id_of(_), do: nil

  @doc """
  Build the broadcast envelope for a typed event struct under `topic`, stamped
  with the topic's monotonic `seq` and the current wall-clock time.
  """
  @spec to_event(t(), topic(), pos_integer()) :: event()
  def to_event(%struct_module{} = data, topic, seq)
      when is_integer(seq) and seq >= 1 do
    _ = struct_module

    %{
      topic: topic,
      type: type_of(data),
      run_id: run_id_of(data),
      seq: seq,
      data: data,
      emitted_at: DateTime.utc_now()
    }
  end
end

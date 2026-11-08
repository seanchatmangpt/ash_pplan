defmodule AshPPlan.Reactor.Durable.Store do
  @moduledoc """
  Persistence behaviour for the durable engine. Every write defines its losing behaviour
  (insert-or-adopt, consume-once, guarded transition), so concurrent attempts cannot corrupt a run.
  `store` is a pid or registered name accepted by the implementation module.
  """
  alias AshPPlan.Reactor.Durable.{Checkpoint, Record, Signal, Waiter}

  @type store :: pid() | atom()
  @type id :: String.t()

  # runs
  @callback start_run(store, attrs :: map()) :: {:ok, Record.t()} | {:error, :exists}
  @callback get_run(store, id) :: Record.t() | nil
  @callback list_runs(store) :: [Record.t()]
  @doc "Guarded transition: applies only if the run's status is in `from` (or `:any` non-terminal); bumps version."
  @callback transition(store, id, from :: [atom()] | :any, to :: atom(), attrs :: map()) ::
              {:ok, Record.t()} | {:error, :stale | :not_found | :illegal}
  @doc "Claim free if unclaimed, lease lapsed, or the same claimer re-enters. nil claimer never re-enters. Persists `lease_ms`/`lease_until` on the record; a nil lease fails closed."
  @callback claim(store, id, claimer :: term(), lease_ms :: pos_integer(), now :: DateTime.t()) ::
              {:ok, Record.t()} | :taken
  @callback release_claim(store, id, claimer :: term()) :: :ok
  @doc """
  Heartbeat CAS: extends the holder's lease only if `claimer` still holds the claim; a stolen
  or absent claim answers `:taken`. Uses the injectable `Clock` for `now`.
  """
  @callback renew_claim(store, id, claimer :: term(), lease_ms :: pos_integer()) ::
              {:ok, Record.t()} | :taken

  # checkpoints
  @callback checkpoints(store, id) :: %{binary() => Checkpoint.t()}
  @callback standing(store, id) :: [Checkpoint.t()]
  @doc """
  One consistent read of the run and its standing checkpoints, checkpoints in
  ascending `seq` order as of a single store message (seq-capped snapshot).
  Optional: `AshPPlan.Reactor.Durable.LedgerOCEL` falls back to `get_run` +
  `standing` (unsorted, sorted by the caller) when the implementation omits it.
  """
  @callback snapshot(store, id) :: {Record.t(), [Checkpoint.t()]} | nil
  @optional_callbacks snapshot: 2, renew_claim: 4
  @doc "Insert-or-adopt: when a row for (run, key) exists, return the standing one. A run in a terminal status refuses NEW checkpoints; `:cancelling` refuses new checkpoints with `{:error, :cancelling}` (adoption of an existing key is unchanged in both cases)."
  @callback record(
              store,
              id,
              step_key :: binary(),
              label :: String.t(),
              output :: term(),
              meta :: map()
            ) ::
              {:ok, Checkpoint.t()} | {:error, :terminal | :cancelling}
  @doc """
  Claim the undo of one standing checkpoint as a VOLATILE leased claim in store server state:
  it blocks re-claims until released, marked, or expired, but is deliberately not persisted -
  a store restart (or lease lapse) leaves the checkpoint standing again, so a crash between
  claim and effect re-runs the undo (at-least-once) instead of hiding a never-executed effect
  behind a premature `undone_at` mark.
  """
  @callback claim_undo(store, id, step_key :: binary(), now :: DateTime.t()) ::
              {:ok, Checkpoint.t()} | :taken
  @doc "Guarded idempotent mark: writes `undone_at` only AFTER the undo effect succeeded."
  @callback mark_undone(store, id, step_key :: binary(), now :: DateTime.t()) ::
              {:ok, Checkpoint.t()} | {:error, :not_found}
  @callback release_undo(store, id, step_key :: binary()) :: :ok

  # signals and waiters
  @doc """
  Atomic consume-once signal take in ONE store message (mailbox-serializable): FIFO-find the
  first pending signal for (run, name); `:none` when absent. When a checkpoint for `step_key`
  already exists (crash-after-commit replay), adopt it: mark the signal consumed, release the
  waiter and return the standing checkpoint unchanged. Otherwise insert the checkpoint
  (output = signal payload), mark the signal consumed and delete the waiter, committed together
  (DETS syncs / WAL appends before the reply). STRICT law: with NO pending signal the answer is
  `:none` for every step key — adoption fires only in response to a pending signal, never
  adopt-regardless (engine crash recovery replays from the standing checkpoint set). Consumed
  signal + recorded checkpoint + released
  waiter is one linearizable transition, closing the consume-once crash window where a kill
  between `consume_signal` and `record` lost the signal (at-least-once re-delivery needed) or
  double-delivered it.
  """
  @callback take_signal(
              store,
              id,
              name :: String.t(),
              step_key :: binary(),
              label :: String.t(),
              meta :: map(),
              now :: DateTime.t()
            ) ::
              {:ok, Checkpoint.t()} | :none
  @callback deliver_signal(store, id, name :: String.t(), payload :: term()) :: {:ok, Signal.t()}
  @callback pending_signal(store, id, name :: String.t()) :: Signal.t() | nil
  @callback consume_signal(store, signal_id :: term(), now :: DateTime.t()) ::
              {:ok, Signal.t()} | :taken
  @doc "Insert when absent; when present return the existing waiter unchanged unless `overwrite: true`."
  @callback park(
              store,
              id,
              name :: String.t(),
              kind :: :signal | :poll,
              deadline :: DateTime.t() | nil,
              opts :: keyword()
            ) ::
              {:ok, Waiter.t()}
  @callback get_waiter(store, id, name :: String.t()) :: Waiter.t() | nil
  @callback waiters(store, id) :: [Waiter.t()]
  @callback release(store, id, name :: String.t()) :: :ok
  @callback release_all(store, id) :: :ok
  @callback signals(store, id) :: [Signal.t()]
end

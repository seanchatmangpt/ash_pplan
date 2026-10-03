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
  @doc "Claim free if unclaimed, lease lapsed, or the same claimer re-enters. nil claimer never re-enters."
  @callback claim(store, id, claimer :: term(), lease_ms :: pos_integer(), now :: DateTime.t()) ::
              {:ok, Record.t()} | :taken
  @callback release_claim(store, id, claimer :: term()) :: :ok

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
  @optional_callbacks snapshot: 2
  @doc "Insert-or-adopt: when a row for (run, key) exists, return the standing one."
  @callback record(
              store,
              id,
              step_key :: binary(),
              label :: String.t(),
              output :: term(),
              meta :: map()
            ) ::
              {:ok, Checkpoint.t()} | {:error, :terminal}
  @callback claim_undo(store, id, step_key :: binary(), now :: DateTime.t()) ::
              {:ok, Checkpoint.t()} | :taken
  @callback release_undo(store, id, step_key :: binary()) :: :ok

  # signals and waiters
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

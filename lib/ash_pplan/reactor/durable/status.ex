defmodule AshPPlan.Reactor.Durable.Status do
  @moduledoc """
  Run status machine with guarded transitions. A terminal status is absorbing and no
  transition may overwrite it (magma allowed unconditional overwrites; we do not).
  """

  @type t ::
          :pending
          | :waiting
          | :polling
          | :unwinding
          | :cancelling
          | :unwind_blocked
          | :completed
          | :failed
          | :cancelled

  @all ~w(pending waiting polling unwinding cancelling unwind_blocked completed failed cancelled)a
  @terminal ~w(completed failed cancelled)a
  @parked ~w(waiting polling)a

  # from => allowed tos
  @allowed %{
    pending: ~w(pending waiting polling unwinding cancelling completed failed)a,
    waiting: ~w(pending waiting polling unwinding cancelling completed failed)a,
    polling: ~w(pending waiting polling unwinding cancelling completed failed)a,
    unwinding: ~w(failed unwind_blocked)a,
    cancelling: ~w(cancelled unwind_blocked)a,
    unwind_blocked: ~w(unwinding cancelling failed cancelled)a,
    completed: [],
    failed: [],
    cancelled: []
  }

  @spec all() :: [t()]
  def all, do: @all
  @spec terminal?(t()) :: boolean()
  def terminal?(s), do: s in @terminal
  @spec parked?(t()) :: boolean()
  def parked?(s), do: s in @parked
  @spec rolling_back?(t()) :: boolean()
  def rolling_back?(s), do: s in [:unwinding, :cancelling]

  @spec can?(t(), t()) :: boolean()
  def can?(from, to), do: to in Map.get(@allowed, from, [])

  # pending -> pending is a legal self-transition: it lets a same-status guarded write
  # (e.g. Migration.apply's commit) bump version/attrs without a stranding intermediate
  # status — a crash between two transitions used to leave a run stuck in :waiting.
  @doc "Cancel is only legal from a non-terminal, non-rolling-back status."
  @spec cancellable?(t()) :: boolean()
  def cancellable?(s), do: s in [:pending, :waiting, :polling]
end

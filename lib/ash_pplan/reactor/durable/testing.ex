defmodule AshPPlan.Reactor.Durable.Testing do
  @moduledoc """
  Deterministic helpers for driving the durable engine in tests, without sleeping.

  `drain/2` is the whole scheduler: it repeatedly asks `Engine.runnable/2` which runs are
  level-triggered runnable and attempts each, until nothing is runnable (or `max_rounds`). With
  `advance: :next_deadline` it then moves the test `Clock` to the earliest waiter deadline of a
  parked run and goes again, so a timeout is crossed by arithmetic, not by `Process.sleep/1`.

  `tape/2` is the standing ledger as labels in checkpoint order; `recorded/3` reads one step's
  recorded output; `age_deadline/4` pulls a parked waiter's measured deadline into the past (the
  one place a deadline is rewritten, and only from a test).

  Design derived from mbuhot/magma (MIT per its mix.exs).
  """

  alias AshPPlan.Reactor.Durable.{Clock, Engine, Key, Status}

  @default_store_module AshPPlan.Reactor.Durable.Store.Ets

  @type store :: pid() | atom()

  @doc """
  Attempt runnable runs until the store is quiescent. Returns the list of `{run_id, outcome}`
  in attempt order.

  Options: `:max_rounds` (default 50), `:advance` (`nil | :next_deadline`), `:store_module`.
  """
  @spec drain(store(), keyword()) :: [{String.t(), term()}]
  def drain(store, opts \\ []) do
    drain(store, opts, Keyword.get(opts, :max_rounds, 50), [])
  end

  defp drain(_store, _opts, 0, acc), do: Enum.reverse(acc)

  defp drain(store, opts, rounds, acc) do
    case Engine.runnable(store, Clock.now()) do
      [] ->
        if opts[:advance] == :next_deadline and advance_to_next_deadline(store, opts) do
          drain(store, opts, rounds - 1, acc)
        else
          Enum.reverse(acc)
        end

      ids ->
        attempt_opts = Keyword.take(opts, [:store_module])
        outcomes = Enum.map(ids, fn id -> {id, Engine.attempt(store, id, attempt_opts)} end)
        drain(store, opts, rounds - 1, Enum.reverse(outcomes, acc))
    end
  end

  # Move the clock to the earliest future waiter deadline of any parked run. false if none.
  defp advance_to_next_deadline(store, opts) do
    mod = store_module(opts)
    now = Clock.now()

    deadlines =
      for run <- mod.list_runs(store),
          Status.parked?(run.status),
          w <- mod.waiters(store, run.id),
          w.deadline != nil,
          DateTime.compare(w.deadline, now) == :gt,
          do: w.deadline

    case Enum.sort(deadlines, DateTime) do
      [] ->
        false

      [earliest | _] ->
        Clock.advance(max(DateTime.diff(earliest, now, :millisecond), 1))
        true
    end
  end

  @doc "Standing checkpoint labels for a run, in checkpoint order."
  @spec tape(store(), String.t()) :: [String.t()]
  def tape(store, run_id), do: store |> Engine.steps(run_id) |> Enum.map(& &1.label)

  @doc "Recorded output of the step named `name` (a Reactor step name), or `nil`."
  @spec recorded(store(), String.t(), term()) :: term()
  def recorded(store, run_id, name) do
    key = Key.for_name(name)

    case Enum.find(Engine.steps(store, run_id), &(&1.step_key == key)) do
      nil -> nil
      cp -> cp.output
    end
  end

  @doc "Current status of a run, or `nil` when it does not exist."
  @spec status(store(), String.t()) :: Status.t() | nil
  def status(store, run_id) do
    case Engine.fetch(store, run_id) do
      %{status: status} -> status
      {:ok, %{status: status}} -> status
      _ -> nil
    end
  end

  @doc "Move the measured deadline of waiter `name` back by `ms`, so the next attempt sees it due."
  @spec age_deadline(store(), String.t(), String.t(), non_neg_integer(), keyword()) :: :ok
  def age_deadline(store, run_id, name, ms, opts \\ []) do
    mod = store_module(opts)

    case mod.get_waiter(store, run_id, name) do
      %{deadline: %DateTime{} = deadline, kind: kind} ->
        {:ok, _} =
          mod.park(store, run_id, name, kind, Clock.add(deadline, -ms), overwrite: true)

        :ok

      other ->
        raise ArgumentError, "no waiter with a deadline for #{inspect(name)}: #{inspect(other)}"
    end
  end

  @doc "Deliver a signal and wake the run."
  @spec signal(store(), String.t(), String.t(), term()) :: {:ok, term()}
  def signal(store, run_id, name, payload \\ true),
    do: Engine.signal(store, run_id, name, payload)

  @doc "Names of every waiter currently parked on a run."
  @spec waiting_on(store(), String.t(), keyword()) :: [String.t()]
  def waiting_on(store, run_id, opts \\ []),
    do: store_module(opts).waiters(store, run_id) |> Enum.map(& &1.name)

  defp store_module(opts), do: Keyword.get(opts, :store_module, @default_store_module)
end

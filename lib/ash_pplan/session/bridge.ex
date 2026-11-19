defmodule AshPPlan.Session.Bridge do
  @moduledoc """
  Binds a connection session to the durable store: hydrate a session's run from the store,
  park it awaiting a signal (e.g. `"step_up"`), and deliver that signal exactly once.

  The bridge wraps `AshPPlan.Reactor.Durable.Engine.signal/5` and `Engine.wake/3`; the engine is
  not modified. All functions take `opts` forwarded to the engine (`:store_module`, e.g.
  `AshPPlan.Reactor.Durable.Store.Dets`).

  Resume law: a signal is accepted only for a run that exists and holds a waiter of that name,
  and only once per name. A second delivery is `{:error, :duplicate_signal}`; a signal for a run
  with no such waiter is `{:error, :not_parked}`; neither writes to the store.
  """

  alias AshPPlan.Reactor.Durable.{Engine, Run}

  @type hydrated :: %{
          id: String.t(),
          status: atom(),
          parked?: boolean(),
          waiting_on: [String.t()]
        }

  @doc "Park a run awaiting `name`: registers the signal waiter and moves it to `:waiting`."
  @spec park(term(), String.t(), String.t(), keyword()) ::
          {:ok, hydrated()} | {:error, term()}
  def park(store, run_id, name, opts \\ []) when is_binary(name) do
    mod = Run.store_module(opts)

    case mod.get_run(store, run_id) do
      nil ->
        {:error, :no_such_run}

      _record ->
        {:ok, _waiter} = mod.park(store, run_id, name, :signal, nil, [])

        case mod.transition(store, run_id, [:pending, :waiting, :polling], :waiting, %{}) do
          {:ok, _} -> hydrate(store, run_id, opts)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc "Read a session's durable state back from the store."
  @spec hydrate(term(), String.t(), keyword()) :: {:ok, hydrated()} | {:error, :no_such_run}
  def hydrate(store, run_id, opts \\ []) do
    mod = Run.store_module(opts)

    case mod.get_run(store, run_id) do
      nil ->
        {:error, :no_such_run}

      record ->
        waiting_on = store |> mod.waiters(run_id) |> Enum.map(& &1.name) |> Enum.sort()

        {:ok,
         %{
           id: record.id,
           status: record.status,
           parked?: record.status in [:waiting, :polling],
           waiting_on: waiting_on
         }}
    end
  end

  @doc """
  Deliver signal `name` to a parked run exactly once, then wake it. Returns
  `{:ok, %{signal: signal, status: status}}` where `status` is the run's status after wake.
  """
  @spec signal(term(), String.t(), String.t(), term(), keyword()) ::
          {:ok, %{signal: struct(), status: atom()}}
          | {:error, :no_such_run | :not_parked | :duplicate_signal | term()}
  def signal(store, run_id, name, payload, opts \\ []) when is_binary(name) do
    mod = Run.store_module(opts)

    with %{} <- mod.get_run(store, run_id) || {:error, :no_such_run},
         :ok <- require_waiter(mod, store, run_id, name),
         :ok <- require_first_delivery(mod, store, run_id, name),
         {:ok, sig} <- Engine.signal(store, run_id, name, payload, opts) do
      _ = Engine.wake(store, run_id, opts)
      status = mod.get_run(store, run_id).status
      {:ok, %{signal: sig, status: status}}
    else
      {:error, _} = err -> err
    end
  end

  defp require_waiter(mod, store, run_id, name) do
    case mod.get_waiter(store, run_id, name) do
      nil -> {:error, :not_parked}
      _ -> :ok
    end
  end

  defp require_first_delivery(mod, store, run_id, name) do
    if Enum.any?(mod.signals(store, run_id), &(&1.name == name)),
      do: {:error, :duplicate_signal},
      else: :ok
  end
end

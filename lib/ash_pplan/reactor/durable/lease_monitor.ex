defmodule AshPPlan.Reactor.Durable.LeaseMonitor do
  @moduledoc """
  Erlang OTP release principle: Monotonic Ephemeral Leases as Heartbeat Claims.

  Structures execution leases as `{owner_pid, epoch, ref}` with BEAM `Process.monitor/1`.
  If a worker dies, the `:DOWN` monitor signal immediately marks the lease abandoned,
  eliminating the 30-second zombie wait window on node/worker crashes.
  """

  use GenServer

  defstruct [:table, :monitors]

  @name __MODULE__

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc "Attempts to claim a run for `pid` under a monotonic epoch. Returns `{:ok, epoch}` or `{:error, :claimed}`."
  def claim(server \\ @name, run_id, pid) when is_pid(pid) do
    GenServer.call(server, {:claim, run_id, pid})
  end

  @doc "Releases a run claim for `pid`."
  def release(server \\ @name, run_id, pid) when is_pid(pid) do
    GenServer.call(server, {:release, run_id, pid})
  end

  @doc "Heartbeat renewing the claim."
  def heartbeat(server \\ @name, run_id, pid) when is_pid(pid) do
    GenServer.call(server, {:heartbeat, run_id, pid})
  end

  @doc "Checks the current lease status of a run. Returns `{:held, pid, epoch}` or `:vacant`."
  def status(server \\ @name, run_id) do
    GenServer.call(server, {:status, run_id})
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(:ash_pplan_lease_claims, [:set, :private])
    {:ok, %__MODULE__{table: table, monitors: %{}}}
  end

  @impl true
  def handle_call({:claim, run_id, pid}, _from, state) do
    case :ets.lookup(state.table, run_id) do
      [{^run_id, held_pid, epoch, _ref}] when held_pid != pid ->
        {:reply, {:error, {:claimed, held_pid, epoch}}, state}

      [{^run_id, ^pid, epoch, _ref}] ->
        {:reply, {:ok, epoch}, state}

      [] ->
        ref = Process.monitor(pid)
        epoch = 1
        :ets.insert(state.table, {run_id, pid, epoch, ref})
        monitors = Map.put(state.monitors, ref, run_id)
        {:reply, {:ok, epoch}, %{state | monitors: monitors}}
    end
  end

  @impl true
  def handle_call({:release, run_id, pid}, _from, state) do
    case :ets.lookup(state.table, run_id) do
      [{^run_id, ^pid, _epoch, ref}] ->
        Process.demonitor(ref, [:flush])
        :ets.delete(state.table, run_id)
        monitors = Map.delete(state.monitors, ref)
        {:reply, :ok, %{state | monitors: monitors}}

      _ ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:heartbeat, run_id, pid}, _from, state) do
    case :ets.lookup(state.table, run_id) do
      [{^run_id, ^pid, epoch, ref}] ->
        new_epoch = epoch + 1
        :ets.insert(state.table, {run_id, pid, new_epoch, ref})
        {:reply, {:ok, new_epoch}, state}

      _ ->
        {:reply, {:error, :not_held}, state}
    end
  end

  @impl true
  def handle_call({:status, run_id}, _from, state) do
    reply =
      case :ets.lookup(state.table, run_id) do
        [{^run_id, pid, epoch, _ref}] -> {:held, pid, epoch}
        [] -> :vacant
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {run_id, monitors} when not is_nil(run_id) ->
        :ets.delete(state.table, run_id)
        {:noreply, %{state | monitors: monitors}}

      {nil, _monitors} ->
        {:noreply, state}
    end
  end
end

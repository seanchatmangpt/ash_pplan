defmodule AshPPlan.Test.FulfillmentRobot do
  @moduledoc """
  Real OTP state machine standing in for the pick robot.

  States: `:idle :picking :carrying :packing_station :fault`. `{:pick, sku}`
  moves idle -> picking -> carrying -> packing_station on a short timer; `:fault`
  is entered via `fault/1`. Subscribers receive `{:robot_event, pid, state}`.
  """
  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @doc "Send a command. Returns `:ok` or `{:error, reason}`."
  def command(pid, {:pick, _sku} = cmd), do: GenServer.call(pid, {:command, cmd})
  def subscribe(pid, subscriber \\ self()), do: GenServer.call(pid, {:subscribe, subscriber})
  def state(pid), do: GenServer.call(pid, :state)
  def command_count(pid), do: GenServer.call(pid, :command_count)
  def fault(pid), do: GenServer.call(pid, :fault)
  def reset(pid), do: GenServer.call(pid, :reset)

  @impl true
  def init(opts) do
    {:ok,
     %{
       state: :idle,
       step_ms: Keyword.get(opts, :step_ms, 10),
       subs: MapSet.new(),
       count: 0,
       sku: nil
     }}
  end

  @impl true
  def handle_call({:command, {:pick, sku}}, _from, %{state: :idle} = s) do
    s = %{s | count: s.count + 1, sku: sku} |> transition(:picking)
    Process.send_after(self(), {:advance, :carrying}, s.step_ms)
    {:reply, :ok, s}
  end

  def handle_call({:command, _}, _from, s),
    do: {:reply, {:error, {:busy, s.state}}, %{s | count: s.count + 1}}

  def handle_call({:subscribe, pid}, _from, s),
    do: {:reply, :ok, %{s | subs: MapSet.put(s.subs, pid)}}

  def handle_call(:state, _from, s), do: {:reply, s.state, s}
  def handle_call(:command_count, _from, s), do: {:reply, s.count, s}
  def handle_call(:fault, _from, s), do: {:reply, :ok, transition(s, :fault)}
  def handle_call(:reset, _from, s), do: {:reply, :ok, transition(s, :idle)}

  @impl true
  def handle_info({:advance, :carrying}, %{state: :picking} = s) do
    Process.send_after(self(), {:advance, :packing_station}, s.step_ms)
    {:noreply, transition(s, :carrying)}
  end

  def handle_info({:advance, :packing_station}, %{state: :carrying} = s),
    do: {:noreply, transition(s, :packing_station)}

  def handle_info({:advance, _}, s), do: {:noreply, s}

  defp transition(s, new) do
    Enum.each(s.subs, &send(&1, {:robot_event, self(), new}))
    %{s | state: new}
  end
end

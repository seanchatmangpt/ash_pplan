defmodule AshPPlan.FOND.Supervision.Registry do
  use GenServer
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, %{}, opts)
  def put(pid, id, p), do: GenServer.call(pid, {:put, id, p})
  def list(pid), do: GenServer.call(pid, :list)
  def init(s), do: {:ok, s}
  def handle_call({:put, id, p}, _, s), do: {:reply, :ok, Map.put(s, id, p)}
  def handle_call(:list, _, s), do: {:reply, Enum.sort_by(s, &elem(&1, 0)), s}
end

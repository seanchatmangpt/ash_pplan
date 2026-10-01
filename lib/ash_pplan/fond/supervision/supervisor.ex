defmodule AshPPlan.FOND.Supervision.Supervisor do
  use GenServer
  alias AshPPlan.FOND.Supervision.Engine
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  def select(pid), do: GenServer.call(pid, :select)
  def observe(pid, o), do: GenServer.call(pid, {:observe, o})

  def init(opts),
    do:
      {:ok,
       Engine.new(
         Keyword.fetch!(opts, :domain),
         Keyword.fetch!(opts, :initial),
         Keyword.get(opts, :candidates, [])
       )}

  def handle_call(:select, _, s) do
    {r, n} = Engine.select(s)
    {:reply, r, n}
  end

  def handle_call({:observe, o}, _, s) do
    {r, n} = Engine.observe(s, o)
    {:reply, r, n}
  end
end

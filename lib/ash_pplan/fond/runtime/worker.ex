defmodule AshPPlan.FOND.Runtime.Worker do
 use GenServer
 def start_link(opts), do: GenServer.start_link(__MODULE__,opts)
 def run(pid,g,s,p), do: GenServer.call(pid,{:run,g,s,p},p.timeout_ms+1_000)
 def init(opts), do: {:ok,opts}
 def handle_call({:run,g,s,p},_,state), do: {:reply,AshPPlan.FOND.Runtime.Engine.run(g,s,p),state}
end
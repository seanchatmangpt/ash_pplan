defmodule AshPPlan.FOND.Runtime.Registry do
 use GenServer
 def start_link(opts \\ []), do: GenServer.start_link(__MODULE__,%{},Keyword.put_new(opts,:name,__MODULE__))
 def register(s \\ __MODULE__,spec), do: GenServer.call(s,{:register,spec})
 def providers(s \\ __MODULE__,cap), do: GenServer.call(s,{:providers,cap})
 def init(s), do: {:ok,s}
 def handle_call({:register,x},_,s), do: {:reply,:ok,Map.put(s,x.id,x)}
 def handle_call({:providers,c},_,s), do: {:reply,s|>Map.values()|>Enum.filter(&AshPPlan.FOND.Runtime.ProviderSpec.supports?(&1,c))|>Enum.sort_by(& &1.priority),s}
end
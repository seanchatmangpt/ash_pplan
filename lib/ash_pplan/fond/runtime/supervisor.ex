defmodule AshPPlan.FOND.Runtime.Supervisor do
 use Supervisor
 def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__,opts,name:__MODULE__)
 def init(_), do: Supervisor.init([AshPPlan.FOND.Runtime.Registry,AshPPlan.FOND.Runtime.HealthStore],strategy: :rest_for_one)
end
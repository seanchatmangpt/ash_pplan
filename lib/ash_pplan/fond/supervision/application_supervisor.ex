defmodule AshPPlan.FOND.Supervision.ApplicationSupervisor do
  use Supervisor
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, :ok, opts)

  def init(:ok),
    do:
      Supervisor.init(
        [
          {AshPPlan.FOND.Supervision.Registry, [name: AshPPlan.FOND.Supervision.Registry]},
          {AshPPlan.FOND.Supervision.DynamicSupervisor,
           [name: AshPPlan.FOND.Supervision.DynamicSupervisor]}
        ],
        strategy: :rest_for_one
      )
end

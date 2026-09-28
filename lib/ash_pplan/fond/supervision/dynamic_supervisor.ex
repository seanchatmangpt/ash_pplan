defmodule AshPPlan.FOND.Supervision.DynamicSupervisor do
  use DynamicSupervisor
  def start_link(opts \\ []), do: DynamicSupervisor.start_link(__MODULE__,:ok,opts)
  def start_policy(pid,opts), do: DynamicSupervisor.start_child(pid,{AshPPlan.FOND.Supervision.Supervisor,opts})
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)
end

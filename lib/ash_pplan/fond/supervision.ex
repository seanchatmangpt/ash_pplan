defmodule AshPPlan.FOND.Supervision do
  alias AshPPlan.FOND.Supervision.Engine
  defdelegate new(domain, initial, candidates), to: Engine
  defdelegate select(state), to: Engine
  defdelegate observe(state, outcome), to: Engine
end

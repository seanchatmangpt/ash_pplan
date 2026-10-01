defmodule AshPPlan.FOND.Supervision.Transition do
  alias AshPPlan.FOND.Supervision.State
  def select(%State{} = s, c, bad), do: %{s | selected: c, refused: bad}
  def observe(%State{} = s, o), do: State.record(s, {:observed, o})
  def exclude(%State{} = s, id), do: %{s | excluded: MapSet.put(s.excluded, id), selected: nil}
end

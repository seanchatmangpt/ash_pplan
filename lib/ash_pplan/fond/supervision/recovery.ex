defmodule AshPPlan.FOND.Supervision.Recovery do
  alias AshPPlan.FOND.Supervision.{ExclusionSet,Failure}
  def route(set,id,reason), do: case Failure.classify(reason) do :local->{:repair_local,set}; _->{:reselect,ExclusionSet.exclude(set,id)} end
end

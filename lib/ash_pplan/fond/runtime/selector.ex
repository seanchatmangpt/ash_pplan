defmodule AshPPlan.FOND.Runtime.Selector do
 @moduledoc false
 def choose(xs,excluded \\ MapSet.new()),do: xs |> Enum.reject(&MapSet.member?(excluded,&1.id)) |> Enum.sort_by(&{&1.score,&1.id}) |> List.first()
end

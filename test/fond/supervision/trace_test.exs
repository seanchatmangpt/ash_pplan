defmodule AshPPlan.FOND.Supervision.TraceTest do
  use ExUnit.Case, async: true
  alias AshPPlan.FOND.Supervision.{Event,Trace}
  test "filters semantic events" do
    t=[] |> Trace.append(Event.selected(:a)) |> Trace.append(Event.refused(:b,:bad)); assert length(Trace.selected(t))==1; assert length(Trace.refusals(t))==1
  end
end

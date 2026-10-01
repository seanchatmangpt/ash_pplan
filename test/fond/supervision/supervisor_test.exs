defmodule AshPPlan.FOND.Supervision.SupervisorTest do
  use ExUnit.Case, async: true
  alias AshPPlan.FOND; alias AshPPlan.FOND.Supervision.{Candidate,Supervisor}
  test "owns selection state in OTP process" do
    {:ok,d}=FOND.new(%{a=>%{go=>[:g]}},[:g]); c=Candidate.new(%{id: :x,policy:%{a=>go},semantics: :strong}); {:ok,p}=Supervisor.start_link(domain:d,initial:a,candidates:[c]); assert {:ok,^c,_}=Supervisor.select(p)
  end
end

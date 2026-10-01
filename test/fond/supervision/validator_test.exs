defmodule AshPPlan.FOND.Supervision.ValidatorTest do
  use ExUnit.Case, async: true
  alias AshPPlan.FOND; alias AshPPlan.FOND.Supervision.{Candidate,Validator}
  test "validates exact policy semantics" do
    {:ok,d}=FOND.new(%{a=>%{go=>[:g]}},[:g]); c=Candidate.new(%{id: :x,policy:%{a=>go},semantics: :strong}); assert {:ok,_}=Validator.validate(d,a,c)
  end
end

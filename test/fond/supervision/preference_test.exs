defmodule AshPPlan.FOND.Supervision.PreferenceTest do
  use ExUnit.Case, async: true
  alias AshPPlan.FOND.Supervision.{Candidate,Preference}
  test "prefers strong then cost" do
    a=Candidate.new(%{id: :a,policy:%{},semantics: :strong_cyclic,cost:0}); b=Candidate.new(%{id: :b,policy:%{},semantics: :strong,cost:9}); assert {:ok,^b}=Preference.choose([a,b])
  end
end

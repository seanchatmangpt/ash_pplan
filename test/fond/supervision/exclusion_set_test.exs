defmodule AshPPlan.FOND.Supervision.ExclusionSetTest do
  use ExUnit.Case, async: true
  alias AshPPlan.FOND.Supervision.{Candidate,ExclusionSet}
  test "removes failed edge only" do
    a=Candidate.new(%{id: :a,policy:%{},semantics: :strong}); b=Candidate.new(%{id: :b,policy:%{},semantics: :strong}); assert ExclusionSet.filter([a,b],MapSet.new([:a]))==[b]
  end
end

defmodule AshPPlan.FOND.Supervision.ReselectorTest do
  use ExUnit.Case, async: true
  alias AshPPlan.FOND
  alias AshPPlan.FOND.Supervision.{Candidate, Reselector}

  test "selects remaining admissible policy" do
    {:ok, d} = FOND.new(%{:a => %{:go => [:g]}}, [:g])
    c = Candidate.new(%{id: :x, policy: %{:a => :go}, semantics: :strong})
    assert {:ok, ^c, []} = Reselector.select(d, :a, [c], MapSet.new())
  end
end

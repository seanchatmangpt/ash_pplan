defmodule AshPPlan.FOND.Supervision.CandidateTest do
  use ExUnit.Case, async: true
  alias AshPPlan.FOND.Supervision.Candidate
  test "strong sorts before strong cyclic" do
    a=Candidate.new(%{id: :a,policy:%{},semantics: :strong_cyclic}); b=Candidate.new(%{id: :b,policy:%{},semantics: :strong})
    assert Candidate.stable_key(b)<Candidate.stable_key(a)
  end
end

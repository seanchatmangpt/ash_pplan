defmodule AshPPlan.FOND.Supervision.AdmissionTest do
  use ExUnit.Case, async: true
  alias AshPPlan.FOND
  alias AshPPlan.FOND.Supervision.{Admission, Candidate}

  test "separates refused candidates" do
    {:ok, d} = FOND.new(%{:a => %{:go => [:g]}}, [:g])
    good = Candidate.new(%{id: :g, policy: %{:a => :go}, semantics: :strong})
    bad = Candidate.new(%{id: :b, policy: %{}, semantics: :strong})
    {ok, no} = Admission.admit(d, :a, [good, bad])
    assert length(ok) == 1 and length(no) == 1
  end
end

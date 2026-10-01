defmodule AshPPlan.FOND.Supervision.PortfolioTest do
  use ExUnit.Case, async: true
  alias AshPPlan.FOND.Supervision.{Candidate, Portfolio}

  test "deduplicates identity" do
    c = Candidate.new(%{id: :x, policy: %{}, semantics: :strong})
    assert length(Portfolio.normalize([c, c])) == 1
  end
end

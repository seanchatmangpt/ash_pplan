defmodule AshPPlan.FOND.ResearchWave14Test do
  use ExUnit.Case, async: true

  alias AshPPlan.FOND.Corpus

  test "wave 14 seeded corpus manufacture is replayable" do
    left = Corpus.seeded(16, {17, 31, 53})
    right = Corpus.seeded(16, {17, 31, 53})

    assert left == right
    assert length(left) == 16
    assert Enum.all?(left, &Map.has_key?(&1, :transitions))
  end
end

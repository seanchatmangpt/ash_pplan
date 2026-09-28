defmodule AshPPlan.FOND.CorpusTest do
  use ExUnit.Case, async: true

  alias AshPPlan.FOND.Corpus

  test "seeded corpus is finite deterministic and structurally useful" do
    corpus = Corpus.seeded(24, {3, 5, 7})

    assert corpus == Corpus.seeded(24, {3, 5, 7})
    assert length(corpus) == 24

    assert Enum.all?(corpus, fn item ->
             is_map(item.transitions) and is_list(item.goals) and is_map(item.policy)
           end)
  end
end

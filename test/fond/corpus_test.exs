defmodule AshPPlan.FOND.CorpusTest do
 use ExUnit.Case,async:true
 test "finite corpus" do
  {t,[_],p,:s0}=AshPPlan.FOND.Corpus.retry_chain(4);assert map_size(t)==5 and map_size(p)==4
 end
end

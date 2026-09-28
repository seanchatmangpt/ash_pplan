defmodule AshPPlan.FOND.ResearchWave13Test do
 use ExUnit.Case,async:true
 alias AshPPlan.FOND
 test "wave 13 exact subject and authority" do
  {:ok,d}=FOND.new(%{pending:%{go:[:done]},done:%{}},[:done]);p=%{pending: :go}
  assert byte_size(AshPPlan.FOND.Subject.fingerprint(d,p,:pending,:strong))==64
  assert AshPPlan.FOND.Projection.map(d,p,:pending,:strong).authority=="NONE"
 end
end

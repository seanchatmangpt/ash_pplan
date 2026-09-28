defmodule AshPPlan.FOND.ResearchWave12Test do
  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.FOND.Differential
  alias AshPPlan.Test.TLAReader

  test "wave 12 cross-examines a strong policy independently" do
    {:ok, domain} = FOND.new(%{pending: %{go: [:done]}, done: %{}}, [:done])

    assert {:ok, result} =
             Differential.check(
               domain,
               %{pending: :go},
               :pending,
               :strong,
               &TLAReader.check!/1
             )

    assert result.agreement
    assert result.verdict == :admitted
  end
end

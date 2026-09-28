defmodule AshPPlan.FOND.ResearchWave07Test do
  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.FOND.Replay

  test "wave 7 replay binds exact subject and render identities" do
    {:ok, domain} =
      FOND.new(%{pending: %{go: [:pending, :done]}, done: %{}}, [:done])

    assert {:ok, bundle} =
             Replay.build(domain, %{pending: :go}, :pending, :strong_cyclic,
               seed: {7, 11, 13}
             )

    assert bundle.subject.id =~ ~r/^sha256:[0-9a-f]{64}$/
    assert bundle.tla.subject_sha256 =~ ~r/^[0-9a-f]{64}$/
  end
end

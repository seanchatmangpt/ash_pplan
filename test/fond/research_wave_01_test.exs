defmodule AshPPlan.FOND.ResearchWave01Test do
  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.FOND.Subject

  test "wave 1 binds the exact FOND policy subject" do
    {:ok, domain} = FOND.new(%{pending: %{go: [:done]}, done: %{}}, [:done])
    subject = Subject.bind(domain, %{pending: :go}, :pending, :strong)

    assert subject.id =~ ~r/^sha256:[0-9a-f]{64}$/
    assert subject.mode == :strong
    assert subject.initial == :pending
  end
end

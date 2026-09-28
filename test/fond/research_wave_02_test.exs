defmodule AshPPlan.FOND.ResearchWave02Test do
  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.FOND.Projection

  test "wave 2 projection remains authority-free" do
    {:ok, domain} = FOND.new(%{pending: %{go: [:done]}, done: %{}}, [:done])
    projection = Projection.portable(domain, %{pending: :go}, :pending, :strong)

    assert projection.authority == :NONE
    assert projection.validator.verdict == :admitted
    assert projection.subject_id =~ ~r/^sha256:[0-9a-f]{64}$/
  end
end

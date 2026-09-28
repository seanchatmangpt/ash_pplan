defmodule AshPPlan.FONDProjectionContractTest do
  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.FOND.Projection

  test "portable projection preserves exact subject and has no authority" do
    {:ok, domain} =
      FOND.new(%{pending: %{attempt: [:pending, :done]}, done: %{}}, [:done])

    projection = Projection.portable(domain, %{pending: :attempt}, :pending, :strong_cyclic)

    assert projection.schema == "ash_pplan/fond-projection/v1"
    assert projection.authority == :NONE
    assert projection.subject_id =~ ~r/^sha256:[0-9a-f]{64}$/
    assert projection.validator.verdict == :admitted
    assert Enum.any?(projection.edges, &(&1.from == :pending and &1.to == :done))
  end

  test "portable refusal remains refusal rather than authority or success" do
    {:ok, domain} = FOND.new(%{pending: %{fail: [:dead]}, dead: %{}, done: %{}}, [:done])
    projection = Projection.portable(domain, %{pending: :fail}, :pending, :strong_cyclic)

    assert projection.authority == :NONE
    assert projection.validator.verdict == :refused
  end
end

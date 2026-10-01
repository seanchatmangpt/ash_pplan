defmodule AshPPlan.FOND.ReplayTest do
  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.FOND.Replay

  test "same exact subject and seed manufacture the same replay identity" do
    {:ok, domain} =
      FOND.new(%{pending: %{go: [:pending, :done]}, done: %{}}, [:done])

    opts = [seed: {7, 11, 13}]

    assert {:ok, first} =
             Replay.build(domain, %{pending: :go}, :pending, :strong_cyclic, opts)

    assert {:ok, second} =
             Replay.build(domain, %{pending: :go}, :pending, :strong_cyclic, opts)

    assert Replay.fingerprint(first) == Replay.fingerprint(second)
    assert first.subject.id == second.subject.id
  end
end

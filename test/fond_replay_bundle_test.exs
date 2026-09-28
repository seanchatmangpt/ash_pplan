defmodule AshPPlan.FONDReplayBundleTest do
  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.FOND.Replay

  test "replay binds exact subject and rendered manifest" do
    {:ok, domain} =
      FOND.new(%{pending: %{attempt: [:pending, :done]}, done: %{}}, [:done])

    assert {:ok, bundle} =
             Replay.build(domain, %{pending: :attempt}, :pending, :strong_cyclic,
               seed: {11, 29, 47}
             )

    bound = Replay.bind_fingerprint(bundle)

    assert bound.subject.id =~ ~r/^sha256:[0-9a-f]{64}$/
    assert bound.tla.subject_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert bound.replay_fingerprint =~ ~r/^sha256:[0-9a-f]{64}$/
    assert bound.native_verdict == :admitted
  end

  test "derived replay_fingerprint is excluded from its own identity" do
    {:ok, domain} = FOND.new(%{a: %{go: [:done]}, done: %{}}, [:done])
    {:ok, bundle} = Replay.build(domain, %{a: :go}, :a, :strong)
    once = Replay.bind_fingerprint(bundle)
    twice = Replay.bind_fingerprint(once)
    assert once.replay_fingerprint == twice.replay_fingerprint
  end
end

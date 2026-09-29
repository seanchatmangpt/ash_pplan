defmodule AshPPlan.SA2A.ReplayTest do
  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.SA2A.{PolicyCandidate, Replay}

  test "SA2A subject is preserved around deterministic owner replay" do
    {:ok, domain} =
      FOND.new(%{pending: %{attempt: [:pending, :done]}, done: %{}}, [:done])

    request = %{
      subject: "sha256:caller",
      formalism: :fond,
      domain: domain,
      initial: :pending
    }

    {:ok, candidate} = PolicyCandidate.fond(request)

    assert {:ok,
            %{
              subject: "sha256:caller",
              authority: :none,
              standing: :candidate,
              replay_fingerprint: "sha256:" <> digest
            }} = Replay.fond(request, candidate, seed: {11, 29, 47})

    assert byte_size(digest) == 64
  end
end

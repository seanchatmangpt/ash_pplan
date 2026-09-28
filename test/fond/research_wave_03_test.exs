defmodule AshPPlan.FOND.ResearchWave03Test do
  use ExUnit.Case, async: true

  alias AshPPlan.FOND.Recovery

  test "wave 3 routes strong liveness failure without inventing authority" do
    route = Recovery.route(%{reason: :not_strong, losing_states: [:pending]})

    assert route.action == :try_strong_cyclic
    assert route.preserve_subject
    assert route.evidence.losing_states == [:pending]
  end
end

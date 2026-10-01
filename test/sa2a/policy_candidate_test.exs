defmodule AshPPlan.SA2A.PolicyCandidateTest do
  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.SA2A.PolicyCandidate

  test "FOND candidate preserves caller subject and owner planner identity" do
    {:ok, domain} = FOND.new(%{pending: %{finish: [:done]}, done: %{}}, [:done])

    assert {:ok,
            %{
              subject: "sha256:caller",
              formalism: :fond,
              authority: :none,
              standing: :candidate,
              mode: :strong,
              policy: %{pending: :finish},
              planner_subject: %{id: "sha256:" <> planner_digest}
            }} =
             PolicyCandidate.fond(%{
               subject: "sha256:caller",
               formalism: :fond,
               domain: domain,
               initial: :pending
             })

    assert byte_size(planner_digest) == 64
  end

  test "missing FOND inputs are typed refusals" do
    assert {:error, %{code: :missing_domain}} =
             PolicyCandidate.fond(%{subject: "s", initial: :pending})
  end
end

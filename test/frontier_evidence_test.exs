defmodule AshPPlan.FrontierEvidenceTest do
  use ExUnit.Case, async: true

  test "projects control-plane evidence without taking runtime authority" do
    descriptor = %{
      resource: Example.Resource,
      actions: [%{name: :advance, type: :update}],
      closure: %{
        hierarchical_process_semantics?: true,
        nondeterministic_policy_validation?: true,
        background_activation?: true
      },
      authority: %{
        lifecycle_legality: AshStateMachine,
        background_and_temporal_delivery: AshOban,
        queue_runtime: Oban,
        saga_execution: Reactor
      }
    }

    fragment =
      AshPPlan.FrontierEvidence.from_control_plane(
        descriptor,
        {:ok, %{valid?: true, policy: "fond-policy-1"}},
        producer_head: "e6fff05917d0976daa5e052015716d8b7f6857ad",
        standing: "PARTIAL_ALIVE"
      )

    assert fragment.schema == "frontier-evidence/v1"
    assert fragment.producer == "ash_pplan"
    assert fragment.authority_ceiling == "CONSTRUCT"
    assert fragment.artifact_hash =~ ~r/^sha256:[0-9a-f]{64}$/
    assert "oban_schedule" in fragment.refused
    assert "reactor_execution" in fragment.refused
  end

  test "same descriptor and validation produce the same hash" do
    descriptor = %{resource: "Example", closure: %{fond?: true}}
    validation = {:ok, %{valid?: true}}
    opts = [producer_head: "head"]

    first = AshPPlan.FrontierEvidence.from_control_plane(descriptor, validation, opts)
    second = AshPPlan.FrontierEvidence.from_control_plane(descriptor, validation, opts)

    assert first.artifact_hash == second.artifact_hash
  end
end

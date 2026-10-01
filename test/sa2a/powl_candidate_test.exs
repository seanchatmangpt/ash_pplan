defmodule AshPPlan.SA2A.PowlCandidateTest do
  use ExUnit.Case, async: true

  alias AshPPlan.SA2A.PolicyCandidate

  @plan "https://w3id.org/ash-pplan#SubscriptionRenewal"

  test "P-PLAN candidate is authority-free and subject-bound" do
    assert {:ok,
            %{
              subject: "subject-1",
              formalism: :powl,
              authority: :none,
              standing: :candidate,
              plan_iri: @plan,
              plan: %{iri: @plan}
            }} =
             PolicyCandidate.powl(%{
               subject: "subject-1",
               formalism: :powl,
               plan_iri: @plan
             })
  end

  test "unknown plan is refused instead of invented" do
    assert {:error, %{code: :plan_not_found}} =
             PolicyCandidate.powl(%{
               subject: "subject-1",
               formalism: :powl,
               plan_iri: "urn:missing"
             })
  end

  test "missing or non-binary plan iri is refused, never raised" do
    assert {:error, %{code: :missing_plan_iri, authority: :none}} =
             PolicyCandidate.powl(%{subject: "subject-1", formalism: :powl})

    assert {:error, %{code: :missing_plan_iri, authority: :none}} =
             PolicyCandidate.powl(%{
               subject: "subject-1",
               formalism: :powl,
               plan_iri: :not_a_binary
             })
  end
end

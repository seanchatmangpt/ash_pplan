defmodule AshPPlan.FONDDifferentialTest do
  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.FOND.Differential
  alias AshPPlan.Test.TLAReader

  test "native and independent reader agree on admitted strong policy" do
    {:ok, domain} = FOND.new(%{pending: %{finish: [:done]}, done: %{}}, [:done])

    assert {:ok, report} =
             Differential.check(
               domain,
               %{pending: :finish},
               :pending,
               :strong,
               &TLAReader.check!/1
             )

    assert report.agreement
    assert report.verdict == :admitted
    assert report.counterexamples == []
  end

  test "native and independent reader agree on strong retry refusal" do
    {:ok, domain} =
      FOND.new(%{pending: %{attempt: [:pending, :done]}, done: %{}}, [:done])

    assert {:ok, report} =
             Differential.check(
               domain,
               %{pending: :attempt},
               :pending,
               :strong,
               &TLAReader.check!/1
             )

    assert report.verdict == :refused
    assert Enum.any?(report.counterexamples, &(&1.class == :liveness))
  end

  test "mismatch is a typed refusal" do
    {:ok, domain} = FOND.new(%{pending: %{finish: [:done]}, done: %{}}, [:done])
    subject = AshPPlan.FOND.Subject.bind(domain, %{pending: :finish}, :pending, :strong)

    assert {:error, mismatch} =
             Differential.compare(subject, {:ok, %{}}, %{verdict: :refused, kind: :liveness})

    assert mismatch.reason == :differential_mismatch
    refute mismatch.agreement
  end

  test "garbage differential: two refusals with DIFFERENT reasons are a mismatch" do
    {:ok, domain} = FOND.new(%{pending: %{finish: [:done]}, done: %{}}, [:done])
    subject = AshPPlan.FOND.Subject.bind(domain, %{pending: :finish}, :pending, :strong)

    assert {:error, mismatch} =
             Differential.compare(
               subject,
               {:error, %{reason: :missing_policy_action, state: :pending}},
               %{verdict: :refused, kind: :liveness}
             )

    assert mismatch.reason == :differential_mismatch
    refute mismatch.agreement
  end

  test "garbage differential: two refusals naming the SAME reason agree" do
    {:ok, domain} = FOND.new(%{pending: %{finish: [:done]}, done: %{}}, [:done])
    subject = AshPPlan.FOND.Subject.bind(domain, %{pending: :finish}, :pending, :strong)

    assert {:ok, report} =
             Differential.compare(
               subject,
               {:error, %{reason: :missing_policy_action, state: :pending}},
               %{verdict: :refused, kind: :deadlock}
             )

    assert report.agreement
    assert report.verdict == :refused
    assert length(report.counterexamples) == 2
  end

  test "an untyped refusal never agrees with a typed one" do
    {:ok, domain} = FOND.new(%{pending: %{finish: [:done]}, done: %{}}, [:done])
    subject = AshPPlan.FOND.Subject.bind(domain, %{pending: :finish}, :pending, :strong)

    assert {:error, mismatch} =
             Differential.compare(
               subject,
               {:error, "unstructured garbage"},
               %{verdict: :refused, kind: :deadlock}
             )

    assert mismatch.reason == :differential_mismatch
  end
end

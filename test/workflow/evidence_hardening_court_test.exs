defmodule AshPPlan.Workflow.EvidenceHardeningCourtTest do
  @moduledoc """
  ZD2 court hardening: a transient `{:bad_generator, nil}` from
  `ExecutionReceipt.escape_literal/1` via `Evidence.prov/2`
  (runtime.ex -> evidence.ex) put a bare untyped raise on the observation path
  of a durable run.

  Falsifiers:

    1. A nil literal slot reaching the PROV serializer must come back as a
       typed error tuple, naming the field — never `{:bad_generator, nil}`.
    2. A normal run keeps every identity triple: no silent drops.
    3. Anti-vacuity: the same corrupt payload really does crash the
       unhardened serializer (`to_rdf/2`), so the guard is not vacuous.
  """

  use ExUnit.Case, async: true

  alias AshPPlan.ExecutionReceipt
  alias AshPPlan.Examples.UltraCode.Steps
  alias AshPPlan.Workflow.{Evidence, Runtime}

  defp subject_id, do: "sha256:" <> String.duplicate("a", 64)

  defp base_receipt(outcome \\ {:ok, %{ok: true}}) do
    ExecutionReceipt.observe(
      Evidence.plan_iri(subject_id()),
      "hardening-run",
      outcome,
      DateTime.utc_now(),
      System.monotonic_time(:microsecond)
    )
  end

  defp corrupt_receipt(field, value) do
    struct!(base_receipt(), [{field, value}])
  end

  describe "typed literal failures" do
    test "a nil in each literal slot yields the typed error, field named" do
      slots = [
        {:plan_iri, nil},
        {:status, nil},
        {:outcome_digest, nil},
        {:started_at, nil},
        {:finished_at, nil}
      ]

      for {field, nil_value} <- slots do
        assert {:error, %{reason: :invalid_literal, field: ^field, value: nil}} =
                 Evidence.prov(corrupt_receipt(field, nil_value), subject_id())
      end
    end

    test "non-nil garbage is also typed, not rendered as garbage" do
      assert {:error, %{reason: :invalid_literal, field: :outcome_digest, value: %Date{}}} =
               Evidence.prov(corrupt_receipt(:outcome_digest, ~D[2026-10-04]), subject_id())

      assert {:error, %{reason: :invalid_literal, field: :status, value: "succeeded"}} =
               Evidence.prov(corrupt_receipt(:status, "succeeded"), subject_id())
    end

    test "a well-formed receipt still renders, with the workflowSubject identity triple" do
      assert {:ok, prov} = Evidence.prov(base_receipt(), subject_id())
      assert prov =~ ~s(<https://w3id.org/ash-pplan#ExecutionReceipt>)
      assert prov =~ ~s(<https://w3id.org/ash-pplan#workflowSubject>)
      assert prov =~ ~s("#{subject_id()}")
      assert prov =~ Evidence.plan_iri(subject_id())
    end

    test "bind contract unchanged on the ok path" do
      subject = %{id: subject_id(), workflow: %{name: :hardening}}
      assert {:ok, ev} = Evidence.bind(subject, run_id: "r1")
      assert :ok = Evidence.verify(ev, subject.id)
    end
  end

  describe "runtime observation failures are sealed typed" do
    defp state(extra) do
      {:ok, r} = Runtime.resolve(Steps.workflow(), providers: [Steps.Local])
      {:ok, p} = Runtime.plan(Steps.workflow())

      Map.merge(
        %{
          model: Steps.workflow(),
          subject: p.subject,
          registry: r.registry,
          bindings: r.bindings,
          resolutions: r.resolutions,
          attempt: 1
        },
        Map.new(extra)
      )
    end

    test "an unbindable model is a typed observation error with the run id, not a MatchError" do
      s =
        state(run_id: "rt-1")
        |> Map.put(:model, %{id: "nope"})

      assert {:error, %{reason: :unbound_subject, run_id: "rt-1"}} =
               Runtime.observe(s, {:error, :boom})
    end

    test "a nil-valued outcome field is digested, not rendered, and the run completes" do
      frontier = [
        %{id: :a, status: :open, deps: []},
        %{id: :b, status: :open, deps: [:a]}
      ]

      assert {:ok, s} =
               Runtime.run(Steps.workflow(), %{frontier: frontier, nil_field: nil},
                 providers: [Steps.Local]
               )

      assert s.observation.state == :succeeded
      assert :ok = Evidence.verify(s.evidence, s.subject.id)

      prov = s.evidence.prov
      rid = ExecutionReceipt.run_identifier(s.evidence.receipt.run_id)
      digest = s.evidence.receipt.outcome_digest

      for expected <- [
            ~s(<https://w3id.org/ash-pplan#runIdentifier> "#{rid}"),
            ~s(<https://w3id.org/ash-pplan#executionStatus> "succeeded"),
            ~s(<https://w3id.org/ash-pplan#resultDigest> "#{digest}"),
            ~s(<https://w3id.org/ash-pplan#workflowSubject> "#{s.subject.id}")
          ] do
        assert prov =~ expected
      end

      assert prov =~ Evidence.plan_iri(s.subject.id)
    end
  end

  describe "anti-vacuity" do
    test "the unhardened serializer really crashes on the same corrupt payload" do
      corrupt = corrupt_receipt(:outcome_digest, nil)

      assert_raise ArgumentError, fn ->
        ExecutionReceipt.to_rdf(corrupt)
      end
    end

    test "the hardened path returns typed on the same payload" do
      assert {:error, %{reason: :invalid_literal, field: :outcome_digest, value: nil}} =
               Evidence.prov(corrupt_receipt(:outcome_digest, nil), subject_id())
    end
  end
end

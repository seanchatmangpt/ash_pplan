defmodule AshPPlan.Standing.ReceiptPortableProjectionTest do
  @moduledoc """
  Property/round-trip court for `AshPPlan.Standing.PortableProjection`
  (ash_pplan Standing vocabulary -> ggen portable receipt vocabulary,
  RFC-GPACK-001 §54-56). Real state assertions only; the sabotage twin is a
  mutation of the totality property, not a mock.
  """

  use ExUnit.Case, async: true

  alias AshPPlan.Standing.PortableProjection
  alias AshPPlan.Standing.Receipt

  @hex40 String.duplicate("a", 40)
  @hex64 String.duplicate("b", 64)

  # ---- 1. golden projection fixture ---------------------------------------

  describe "golden projections" do
    test "direct counterparts project to themselves" do
      for s <- ~w(ALIVE PARTIAL_ALIVE BLOCKED BUILD_BROKEN UNSUPPORTED) do
        assert {:ok, ^s} = PortableProjection.project_standing(s)
      end
    end

    test "REFUSED(x) projects to REFUSED:x (ggen payload vocabulary)" do
      assert {:ok, "REFUSED:PATH_SAFETY"} = PortableProjection.project_standing("REFUSED:PATH_SAFETY")
      assert {:ok, "REFUSED:R7"} = PortableProjection.project_standing("REFUSED:R7")
    end

    test "golden full report for an anchored ALIVE receipt" do
      report = PortableProjection.projection_report("ALIVE", subject_sha: @hex64, base_sha: @hex64)

      assert report == %{
               ggen_schema: "https://ggen.dev/receipt/pack/v1",
               standing: {:ok, "ALIVE"},
               identity: %{subject_sha: @hex64, base_sha: @hex64, flags: []},
               dispositions: []
             }
    end
  end

  # ---- 2. explicit non-counterparts (never silently dropped) --------------

  describe "non-counterpart dispositions" do
    test "COMPENSATED / COMPENSATION_FAILED / UNKNOWN are dispositioned, not projected" do
      for {s, reason} <- [
            {"COMPENSATED", :compensated},
            {"COMPENSATION_FAILED", :compensation_failed},
            {"UNKNOWN", :unknown_standing}
          ] do
        assert {:no_ggen_counterpart, ^reason} = PortableProjection.project_standing(s)

        report = PortableProjection.projection_report(s)
        assert report.standing == nil

        assert [%{field: :standing, value: ^s, reason: ^reason}] = report.dispositions
      end
    end

    test "every standings/0 value is total: projected OR dispositioned, never dropped" do
      for s <- Receipt.standings() do
        case PortableProjection.project_standing(s) do
          {:ok, _projected} -> :ok
          {:no_ggen_counterpart, _reason} -> :ok
          {:error, %{broken_term: "refused_requires_ggen_payload"}} -> :ok
          other ->
            flunk("standing #{s} is not total (projected or dispositioned): #{inspect(other)}")
        end
      end
    end

    test "bare REFUSED is a typed refusal (ggen requires a payload), not a silent mapping" do
      assert {:error, %{broken_term: "refused_requires_ggen_payload"}} =
               PortableProjection.project_standing("REFUSED")
    end

    test "non-conforming REFUSED payload is refused, not rewritten" do
      assert {:error, %{broken_term: "refused_payload_not_ggen_conformant", payload: "bad-payload"}} =
               PortableProjection.project_standing("REFUSED:bad-payload")
    end
  end

  # ---- 3. identity anchors -------------------------------------------------

  describe "identity anchors" do
    test "64-hex anchors project clean with no flags" do
      assert {:ok, %{subject_sha: @hex64, base_sha: @hex64, flags: []}} =
               PortableProjection.project_identity(subject_sha: @hex64, base_sha: @hex64)
    end

    test "40-hex anchors (ExecutionReceipt convention) project UNCHANGED with a mismatch flag" do
      assert {:ok, identity} = PortableProjection.project_identity(subject_sha: @hex40, base_sha: @hex40)

      assert identity == %{
               subject_sha: @hex40,
               base_sha: @hex40,
               flags: [:sha_length_mismatch, :sha_length_mismatch]
             }

      assert {:ok, identity} = PortableProjection.project_identity(subject_sha: @hex40)
      assert identity == %{subject_sha: @hex40, base_sha: nil, flags: [:sha_length_mismatch]}
    end

    test "mixed 40/64 keeps each anchor's own value and flags only the 40" do
      assert {:ok, %{subject_sha: @hex40, base_sha: @hex64, flags: [:sha_length_mismatch]}} =
               PortableProjection.project_identity(%{subject_sha: @hex40, base_sha: @hex64})
    end

    test "absent anchors are honest absence" do
      assert {:ok, %{subject_sha: nil, base_sha: nil, flags: []}} = PortableProjection.project_identity([])
    end

    test "a present anchor that is neither 40- nor 64-hex is a typed refusal" do
      for bad <- ["", "xyz", String.upcase(@hex64), String.duplicate("a", 63)] do
        assert {:error, {:bad_identity, :subject_sha}} =
                 PortableProjection.project_identity(subject_sha: bad)
      end
    end

    test "real ExecutionReceipt hex enforcement is 40-hex (the mismatch is real, not hypothetical)" do
      receipt = %AshPPlan.ExecutionReceipt{
        plan_iri: "urn:x:p",
        run_id: "r1",
        status: :succeeded,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        duration_us: 1,
        outcome_digest: @hex64
      }

      assert :ok = AshPPlan.ExecutionReceipt.validate_identity(%{receipt | subject_sha: @hex40})
      assert {:error, {:bad_identity, :subject_sha}} =
               AshPPlan.ExecutionReceipt.validate_identity(%{receipt | subject_sha: @hex64})
    end
  end

  # ---- 4. sabotage twin -----------------------------------------------------

  describe "sabotage twin (court fails on mutation)" do
    test "an invented standing value makes the report an error, not a silent pass" do
      report = PortableProjection.projection_report("OMNIPOTENT")

      assert match?({:error, {:unknown_standing, "OMNIPOTENT"}}, report.standing)
      assert report.dispositions == []

      # Totality over the closed set does NOT admit the invented value.
      refute "OMNIPOTENT" in Receipt.standings()
    end

    test "a dropped disposition would fail the non-counterpart check" do
      # If the projection ever silently returned {:ok, _} for a
      # non-counterpart, this closed-set diff would catch it.
      projected =
        for s <- Receipt.standings(),
            match?({:ok, _}, PortableProjection.project_standing(s)),
            do: s

      assert MapSet.difference(MapSet.new(projected), MapSet.new(PortableProjection.direct_standings())) ==
               MapSet.new([])
    end

    test "a truncated 40-hex anchor (classic sabotage) is detectable, not accepted as 64" do
      truncated = String.slice(@hex64, 0, 40)
      assert {:ok, identity} = PortableProjection.project_identity(subject_sha: truncated)
      assert identity == %{subject_sha: truncated, base_sha: nil, flags: [:sha_length_mismatch]}

      # It is NOT confused with a 64-hex anchor.
      refute match?({:ok, %{flags: []}}, PortableProjection.project_identity(subject_sha: truncated))
    end
  end
end

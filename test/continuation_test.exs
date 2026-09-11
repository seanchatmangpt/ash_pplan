defmodule AshPPlan.ContinuationTest do
  use ExUnit.Case, async: true

  alias AshPPlan.Continuation
  alias AshPPlan.Continuation.ETFCodec

  @plan_iri "https://example.test/plans/renewal"
  @run_id "run-123"

  test "captures and restores an exact halted Reactor identity" do
    reactor = halted_reactor()

    assert {:ok, continuation} =
             Continuation.capture(@plan_iri, @run_id, reactor, ETFCodec)

    assert continuation.id =~ "sha256:"
    assert continuation.plan_iri == @plan_iri
    assert continuation.run_id == @run_id
    assert continuation.codec_id == ETFCodec.id()
    assert continuation.codec_version == ETFCodec.version()

    assert {:ok, restored} = Continuation.restore(continuation, ETFCodec)
    assert restored == reactor
  end

  test "refuses payload tampering before decode" do
    assert {:ok, continuation} =
             Continuation.capture(@plan_iri, @run_id, halted_reactor(), ETFCodec)

    tampered = %{continuation | payload: continuation.payload <> <<0>>}

    assert {:error, %{reason: :continuation_payload_digest_mismatch}} =
             Continuation.restore(tampered, ETFCodec)
  end

  test "refuses a reactor whose plan or run identity disagrees with the envelope" do
    assert {:error, %{reason: :plan_identity_mismatch}} =
             Continuation.capture("other-plan", @run_id, halted_reactor(), ETFCodec)

    wrong_run = %{halted_reactor() | context: %{run_id: "other-run"}}

    assert {:error, %{reason: :run_identity_mismatch}} =
             Continuation.capture(@plan_iri, @run_id, wrong_run, ETFCodec)
  end

  test "ETF codec refuses runtime-only identities instead of claiming durability" do
    reactor = %{halted_reactor() | context: %{run_id: @run_id, ephemeral: make_ref()}}

    assert {:error, %{reason: :codec_encode_failed, error: :non_portable_runtime_term}} =
             Continuation.capture(@plan_iri, @run_id, reactor, ETFCodec)
  end

  test "storage attributes preserve the content-addressed envelope" do
    assert {:ok, continuation} =
             Continuation.capture(@plan_iri, @run_id, halted_reactor(), ETFCodec)

    attributes = Continuation.to_attributes(continuation)
    assert attributes.id == continuation.id
    assert attributes.payload == continuation.payload
    assert attributes.payload_sha256 == continuation.payload_sha256
  end

  defp halted_reactor do
    %Reactor{
      id: @plan_iri,
      state: :halted,
      context: %{run_id: @run_id}
    }
  end
end

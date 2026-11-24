defmodule AshPPlan.AffidavitBundleTest do
  @moduledoc """
  Court for the omni-evidence/v1 projection (`AshPPlan.AffidavitBundle`).

  Real collaborators only: real `ExecutionReceipt` structs rendered through the
  real `to_rdf/2`. Anti-vacuity mutation named per test: dropping the qualifier
  from `object_ref/3`, or swapping the payload for the outcome digest, flips the
  identity / payload assertions.

  The cross-repo half (affidavit seals and verifies this bundle) runs in
  affidavit: `tests/omni_bundle_e2e.rs` over `fixtures/omni/ash_pplan/`, which
  is a byte copy of the bundle this court writes.
  """

  use ExUnit.Case, async: true

  alias AshPPlan.AffidavitBundle
  alias AshPPlan.ExecutionReceipt

  @plan "https://w3id.org/ash-pplan#SubscriptionRenewal"

  defp receipt(run_id, status, digest) do
    %ExecutionReceipt{
      plan_iri: @plan,
      run_id: run_id,
      status: status,
      started_at: ~U[2026-11-15 00:00:00Z],
      finished_at: ~U[2026-11-15 00:00:01Z],
      duration_us: 1_000_000,
      outcome_digest: digest,
      repo: "seanchatmangpt/ash_pplan",
      subject_sha: String.duplicate("a", 40)
    }
  end

  defp fixture_receipts do
    [
      receipt("run-1", :succeeded, String.duplicate("1", 64)),
      receipt("run-2", :failed, String.duplicate("2", 64))
    ]
  end

  test "entry carries event type, colon-safe object refs and the RDF payload" do
    [e1, e2] = AffidavitBundle.entries(fixture_receipts())

    assert e1.event_type == "pplan.execution.succeeded"
    assert e2.event_type == "pplan.execution.failed"

    # mutation: dropping the qualifier loses the raw plan IRI -> this fails.
    [run, plan, commit] = e1.objects
    assert [_id, "pplan-run", "run-1"] = String.split(run, ":", parts: 3)
    assert [plan_id, "pplan-plan", @plan] = String.split(plan, ":", parts: 3)
    refute String.contains?(plan_id, ":")
    assert commit == String.duplicate("a", 40) <> ":git-commit:seanchatmangpt/ash_pplan"

    # mutation: swapping payload for the outcome digest -> this fails.
    assert e1.payload == ExecutionReceipt.to_rdf(hd(fixture_receipts()))
    assert e1.payload =~ "resultDigest"
  end

  test "render is deterministic and points payloads at relative paths" do
    entries = AffidavitBundle.entries(fixture_receipts())
    {batch, files} = AffidavitBundle.render(entries)

    assert {^batch, ^files} = AffidavitBundle.render(entries)
    assert [{"payloads/0000.nt", p0}, {"payloads/0001.nt", _}] = files
    assert p0 == hd(entries).payload
    assert batch =~ ~s("payload":"payloads/0000.nt")
    assert batch =~ ~s("event_type":"pplan.execution.failed")
  end

  test "json_string escapes quotes, backslashes and control characters" do
    assert AffidavitBundle.json_string(~s(a"b\\c\nd\u0001)) ==
             ~s("a\\"b\\\\c\\nd\\u0001")
  end

  @tag :tmp_dir
  test "write! lays out batch.json plus payload files", %{tmp_dir: dir} do
    AffidavitBundle.entries(fixture_receipts()) |> AffidavitBundle.write!(dir)

    assert File.read!(Path.join(dir, "payloads/0000.nt")) ==
             ExecutionReceipt.to_rdf(hd(fixture_receipts()))

    {batch, _} = AffidavitBundle.render(AffidavitBundle.entries(fixture_receipts()))
    assert File.read!(Path.join(dir, "batch.json")) == batch
  end
end

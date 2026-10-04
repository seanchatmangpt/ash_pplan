defmodule MarketplaceSim.GcpContractCourtTest do
  @moduledoc """
  Consumer court for the gcp-marketplace-saas-pack Zach-Daniel alignment pass
  (GCP side). The checked-in projection
  test/support/marketplace_sim/gcp_generated/gcp_generated_validation.ex is
  compiled at test boot (elixirc_paths(:test) includes test/support); these
  Chicago tests exercise the REAL generated module -- no mocks.
  """
  use ExUnit.Case, async: false

  alias MarketplaceSim.GcpMarketplace.GeneratedValidation, as: GV

  @root Path.expand("../..", __DIR__)
  @pack "/Users/sac/ggen-marketplace/packs/gcp-marketplace-saas-pack"
  @checked_in Path.join([
                @root,
                "test/support/marketplace_sim/gcp_generated/gcp_generated_validation.ex"
              ])

  # Verified against the live discovery doc (2026-10-03): 8 states.
  @discovery_states [
    "ENTITLEMENT_ACTIVATION_REQUESTED",
    "ENTITLEMENT_ACTIVE",
    "ENTITLEMENT_CANCELLED",
    "ENTITLEMENT_PENDING_CANCELLATION",
    "ENTITLEMENT_PENDING_PLAN_CHANGE",
    "ENTITLEMENT_PENDING_PLAN_CHANGE_APPROVAL",
    "ENTITLEMENT_STATE_UNSPECIFIED",
    "ENTITLEMENT_SUSPENDED"
  ]

  defp ev(event_type, effective_at, event_id) do
    %{
      entitlement_id: "providers/acme/entitlements/e1",
      event_id: event_id,
      event_type: event_type,
      effective_at: effective_at
    }
  end

  defp lifecycle_events do
    id = "providers/acme/entitlements/e1"

    [
      ev("ENTITLEMENT_CREATION_REQUESTED", "2026-01-01T00:00:00Z", id <> "-1"),
      ev("ENTITLEMENT_ACTIVE", "2026-01-02T00:00:00Z", id <> "-2"),
      ev("ENTITLEMENT_PLAN_CHANGE_REQUESTED", "2026-01-03T00:00:00Z", id <> "-3"),
      ev("ENTITLEMENT_PLAN_CHANGED", "2026-01-04T00:00:00Z", id <> "-4"),
      ev("ENTITLEMENT_PENDING_CANCELLATION", "2026-01-05T00:00:00Z", id <> "-5"),
      ev("ENTITLEMENT_CANCELLED", "2026-01-06T00:00:00Z", id <> "-6")
    ]
  end

  test "entitlement state enum is the 8 verified discovery-doc values" do
    assert Enum.sort(GV.entitlement_states()) == Enum.sort(@discovery_states)
  end

  test "transition table is 13 verified event types" do
    expected = [
      "ENTITLEMENT_ACTIVE",
      "ENTITLEMENT_CANCELLATION_REVERTED",
      "ENTITLEMENT_CANCELLED",
      "ENTITLEMENT_CANCELLING",
      "ENTITLEMENT_CREATION_REQUESTED",
      "ENTITLEMENT_DELETED",
      "ENTITLEMENT_OFFER_ACCEPTED",
      "ENTITLEMENT_OFFER_ENDED",
      "ENTITLEMENT_PENDING_CANCELLATION",
      "ENTITLEMENT_PLAN_CHANGED",
      "ENTITLEMENT_PLAN_CHANGE_CANCELLED",
      "ENTITLEMENT_PLAN_CHANGE_REQUESTED",
      "ENTITLEMENT_RENEWED"
    ]

    assert GV.transitions() |> Enum.map(&elem(&1, 0)) |> Enum.sort() == expected
  end

  test "full lifecycle fold: creation -> active -> plan change -> cancelled" do
    state = GV.fold(lifecycle_events())
    assert %GV{} = state
    assert state.status == "ENTITLEMENT_CANCELLED"
    assert state.updated_at == "2026-01-06T00:00:00Z"
    assert state.last_applied_event_id == "providers/acme/entitlements/e1-6"
  end

  test "duplicate event is an idempotent no-op (watermark ==)" do
    s1 = GV.fold(lifecycle_events())
    dup = ev("ENTITLEMENT_CANCELLED", "2026-01-06T00:00:00Z", "providers/acme/entitlements/e1-6")
    s2 = GV.fold(Enum.concat(lifecycle_events(), [dup]))
    assert s2 == s1
  end

  test "stale out-of-order event is a no-op (watermark >)" do
    s1 = GV.fold(lifecycle_events())
    stale = ev("ENTITLEMENT_ACTIVE", "2025-01-01T00:00:00Z", "providers/acme/entitlements/e1-old")
    s2 = GV.fold(Enum.concat(lifecycle_events(), [stale]))
    assert s2 == s1
  end

  test "unknown event type is a typed refusal" do
    refused = GV.reconcile(nil, ev("ENTITLEMENT_MADE_UP", "2026-01-01T00:00:00Z", "x-1"))
    assert {:error, {:unknown_event_type, "ENTITLEMENT_MADE_UP"}} = refused
  end

  test "anti-vacuity: empty event list does NOT yield ACTIVE" do
    state = GV.fold([])
    assert %GV{} = state
    assert state.status == "ENTITLEMENT_STATE_UNSPECIFIED"
    refute state.status == "ENTITLEMENT_ACTIVE"
  end

  test "malformed effective_at is refused before the watermark comparison" do
    refused =
      GV.reconcile(nil, %{
        entitlement_id: "e1",
        event_id: "x-1",
        event_type: "ENTITLEMENT_ACTIVE",
        effective_at: "zzz-not-a-timestamp"
      })

    assert {:error, {:malformed_event, :invalid_effective_at}} = refused
  end

  # --- Service Control report payload ---

  test "report payload matches the Service Control Operation shape" do
    payload =
      GV.build_usage_report(
        "op-123",
        "ecosystem.marketplace.endpoints.google.com",
        "usage-reporting-id-1",
        [
          %{
            metric_name: "ash_pplan.googleapis.com/plan_solves",
            value: 42,
            start_time: "2026-10-03T00:00:00Z",
            end_time: "2026-10-03T01:00:00Z"
          }
        ]
      )

    assert MapSet.new(Map.keys(payload)) == MapSet.new(["serviceName", "operations"])
    assert [op] = payload["operations"]
    assert op["operationId"] == "op-123"
    assert op["operationName"] == "MarketplaceUsageReporting"
    assert op["consumerId"] == "project:usage-reporting-id-1"
    assert is_binary(op["startTime"]) and is_binary(op["endTime"])

    assert [mvs] = op["metricValueSets"]
    assert mvs["metricName"] == "ash_pplan.googleapis.com/plan_solves"

    assert [mv] = mvs["metricValues"]
    assert mv["int64Value"] == "42"
    assert is_binary(mv["int64Value"])
  end

  # --- signup JWT claim checks ---

  defp b64(json), do: json |> Jason.encode!() |> Base.url_encode64(padding: false)

  defp jwt(payload) do
    [b64(%{"alg" => "RS256", "typ" => "JWT"}), b64(payload), "sig"] |> Enum.join(".")
  end

  @iss "https://www.googleapis.com/robot/v1/metadata/x509/cloud-commerce-partner@system.gserviceaccount.com"

  test "valid signup token claims accepted" do
    token =
      jwt(%{
        "iss" => @iss,
        "sub" => "account-1",
        "exp" => 4_999_999_999,
        "aud" => "svc.example.com"
      })

    assert {:ok, payload} =
             GV.validate_signup_token(token, expected_aud: "svc.example.com", now: 1_800_000_000)

    assert payload["sub"] == "account-1"
  end

  test "expired token refused" do
    token = jwt(%{"iss" => @iss, "sub" => "account-1", "exp" => 1_700_000_000})

    assert {:error, %{code: :token_expired}} =
             GV.validate_signup_token(token, now: 1_800_000_000)
  end

  test "wrong issuer refused" do
    token =
      jwt(%{"iss" => "https://evil.example.com/x509/rogue", "sub" => "a", "exp" => 4_999_999_999})

    assert {:error, %{code: :invalid_issuer}} = GV.validate_signup_token(token)
  end

  test "missing sub and wrong aud refused" do
    token = jwt(%{"iss" => @iss, "exp" => 4_999_999_999})
    assert {:error, %{code: :missing_subject}} = GV.validate_signup_token(token)

    token2 = jwt(%{"iss" => @iss, "sub" => "a", "exp" => 4_999_999_999, "aud" => "other"})

    assert {:error, %{code: :invalid_audience}} =
             GV.validate_signup_token(token2, expected_aud: "svc.example.com")
  end

  # --- regeneration (anti-vacuity on the sync itself) ---

  @tag timeout: 900_000
  test "pack re-syncs byte-identically into a run-unique scratch manifest dir" do
    # Run-unique, project-local scratch (manufacture_test precedent) so
    # concurrent suites never share a sync lock.
    scratch_root = Path.expand("../tmp/zd14_court_scratch", __DIR__)
    scratch = Path.join(scratch_root, "run-#{System.unique_integer([:positive])}")
    File.mkdir_p!(scratch)
    out = Path.join(scratch, "gcp_generated_validation.ex")

    on_exit(fn -> File.rm_rf!(scratch_root) end)

    # Subprocess CLI sync: the same `mix ggen_igniter.sync` invocation the
    # manufacture scripts use, so the court exercises the real transport,
    # including the reactor's own `mix compile` verification, without
    # depending on the host ExUnit VM.
    {output, code} =
      System.cmd(
        "mix",
        [
          "ggen_igniter.sync",
          "--pack-dir",
          @pack,
          "--template",
          Path.join(@pack, "templates/gcp_validation.ex.eex"),
          "--engine",
          "oxigraph",
          "--out",
          out,
          "--manifest-dir",
          scratch,
          "--verify-cwd",
          @root
        ],
        cd: @root,
        stderr_to_stdout: true
      )

    assert code == 0, "sync failed (exit #{code}):\n#{output}"

    assert File.regular?(out)

    normalize = fn path ->
      path |> File.read!() |> Code.format_string!() |> IO.iodata_to_binary()
    end

    assert normalize.(out) == normalize.(@checked_in),
           "regenerated projection differs from the checked-in one"
  end
end

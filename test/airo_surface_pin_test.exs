defmodule AshPPlan.AiroSurfacePinTest do
  @moduledoc """
  Pin test for the ash_pplan AIRo surface (lane W682, v26.10.6 AIRo pin series,
  sibling of w675/w677/w678/w681). Pins the committed W635 court surface per the
  AIRo wiring ledger conventions. Real files and modules, no mocks.
  """

  use ExUnit.Case, async: true

  @repo_root Path.expand("..", __DIR__)
  @ttl_path Path.join(@repo_root, "priv/airo_risk_description.ttl")
  @court_test_path Path.join(@repo_root, "test/airo_risk_description_test.exs")

  @vocab_sha "6274d2d8711e046cf38f1b5b2980188094d4aa87b5af79804005a06468fd8469"
  @ttl_sha "5d28a105a957f26b7e5a7578ee3a7495ccdffea6bd3ac5f767133f5789231d3c"
  @ttl_bytes 11_609

  @cited_modules [
    AshPPlan.FOND.Synthesis,
    AshPPlan.FOND.PolicySupervisor.Offers,
    AshPPlan.Reactor.Durable.Engine,
    AshPPlan.Reactor.Durable.Checkpointed,
    AshPPlan.Reactor.Durable.Key,
    AshPPlan.Reactor.Durable.Store,
    AshPPlan.Reactor.Durable.Store.Dets,
    AshPPlan.Reactor.Durable.Store.Ets
  ]

  @cited_paths [
    "lib/ash_pplan/fond/synthesis.ex",
    "lib/ash_pplan/fond/policy_supervisor/offers.ex",
    "lib/ash_pplan/reactor/durable/engine.ex",
    "lib/ash_pplan/reactor/durable/checkpointed.ex",
    "lib/ash_pplan/reactor/durable/key.ex",
    "lib/ash_pplan/reactor/durable/store.ex",
    "lib/ash_pplan/reactor/durable/store/dets.ex",
    "lib/ash_pplan/reactor/durable/store/ets.ex",
    "lib/ash_pplan/reactor/durable/migration.ex",
    "bin/verify-package",
    "bin/gate",
    "test/manufacture_test.exs",
    "lib/ash_pplan/reactor/durable/steps/dispatch.ex",
    "lib/ash_pplan/reactor/durable/steps/poll.ex",
    "lib/ash_pplan/reactor/durable/compensations/dispatch.ex",
    "lib/ash_pplan/reactor/durable/compensations/poll.ex",
    "test/map_update_absent_key_test.exs",
    "test/airo_risk_description_test.exs"
  ]

  test "description file exists with pinned sha256 and byte size" do
    assert File.exists?(@ttl_path), "missing #{@ttl_path}"
    content = File.read!(@ttl_path)
    assert byte_size(content) == @ttl_bytes
    computed = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    assert computed == @ttl_sha, "sha256 drifted: #{computed}"
  end

  test "header cites the ledger vocabulary pin" do
    assert File.read!(@ttl_path) =~ @vocab_sha
  end

  test "W635 court test file exists" do
    assert File.exists?(@court_test_path)
  end

  test "describes an airo:AISystem with AIRo 1.0 structure" do
    content = File.read!(@ttl_path)
    assert content =~ "FondPolicyPlanner a airo:AISystem"
    assert Enum.count(Regex.scan(~r/a airo:Hazard/, content)) >= 3
    assert Enum.count(Regex.scan(~r/a airo:RiskControl/, content)) >= 5
    assert Enum.count(Regex.scan(~r/a airo:Risk\b/, content)) >= 1
  end

  test "every cited repo path exists on disk" do
    missing = Enum.reject(@cited_paths, &File.exists?(Path.join(@repo_root, &1)))
    assert missing == [], "cited paths missing: #{inspect(missing)}"
  end

  test "cited modules are loadable" do
    for mod <- @cited_modules do
      assert {:module, ^mod} = Code.ensure_loaded(mod)
    end
  end
end

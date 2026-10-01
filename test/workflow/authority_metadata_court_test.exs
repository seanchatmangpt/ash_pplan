defmodule AshPPlan.Workflow.AuthorityMetadataCourtTest do
  @moduledoc """
  Court: policy metadata is data, never a grant. `Workflow.Authority.check_metadata/1`
  refuses every authority-bearing key (moved from the removed Supervision.AuthorityGuard).
  Anti-vacuity mutation: a clean map passes while each forbidden key flips it to a refusal,
  so a guard that always returns :ok (or always refuses) fails this court.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Workflow.Authority

  @forbidden [:authority, :do, :actuate, :standing, :token, :credential]

  test "clean metadata is admitted" do
    assert :ok = Authority.check_metadata(%{name: "p", cost: 1})
    assert :ok = Authority.check_metadata(%{})
  end

  for key <- @forbidden do
    test "refuses #{inspect(key)}" do
      assert {:error, {:authority_bearing_policy, unquote(key)}} =
               Authority.check_metadata(Map.put(%{name: "p"}, unquote(key), true))
    end
  end

  test "non-map metadata is refused" do
    assert {:error, :invalid_metadata} = Authority.check_metadata([:authority])
  end
end

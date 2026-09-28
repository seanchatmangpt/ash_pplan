defmodule AshPPlan.FOND.ResearchWave13Test do
  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.FOND.TLA.Manifest

  test "wave 13 content-addresses TLA and TLC configuration bytes" do
    {:ok, domain} = FOND.new(%{pending: %{go: [:done]}, done: %{}}, [:done])
    {:ok, rendered} = FOND.to_tla(domain, %{pending: :go}, :pending, :strong)
    manifest = Manifest.from_rendered(rendered)

    assert manifest.module_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert manifest.cfg_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert Manifest.matches?(manifest, rendered)
  end
end

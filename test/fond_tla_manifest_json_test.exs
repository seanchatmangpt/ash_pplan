defmodule AshPPlan.FONDTLAManifestJSONTest do
  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.FOND.TLA.{JSON, Manifest}

  test "manifest is content-addressed and JSON envelope round-trips" do
    {:ok, domain} = FOND.new(%{a: %{go: [:done]}, done: %{}}, [:done])
    {:ok, rendered} = FOND.to_tla(domain, %{a: :go}, :a, :strong)

    manifest = Manifest.from_rendered(rendered)
    encoded = JSON.encode_map(rendered)

    assert Manifest.matches?(manifest, rendered)
    assert {:ok, decoded} = JSON.decode_map(encoded)
    assert decoded.module == rendered.module
    assert decoded.cfg == rendered.cfg
    assert decoded.mode == :strong
  end

  test "tampered module is refused by bound manifest" do
    {:ok, domain} = FOND.new(%{a: %{go: [:done]}, done: %{}}, [:done])
    {:ok, rendered} = FOND.to_tla(domain, %{a: :go}, :a, :strong)
    encoded = JSON.encode_map(rendered)
    tampered = Map.update!(encoded, "module", &(&1 <> "\n\\* tampered"))

    assert {:error, %{reason: :manifest_mismatch}} = JSON.decode_map(tampered)
  end
end

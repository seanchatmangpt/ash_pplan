defmodule AshPPlan.CapabilityPackTest do
  @moduledoc """
  Capability pack court. Falsifies: packs with bad capabilities, empty
  declarations, duplicates, or an authority ceiling above `:construct` being
  loaded, and the SHACL shape drifting from the validator. Mutations cover each
  refusal path.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.CapabilityPack

  @valid %{
    id: "local",
    capabilities: ["File.Read", "Process.Run"],
    properties: [:durable],
    evidence: [:receipt]
  }

  test "loads a valid pack with atom or string keys" do
    assert {:ok, %CapabilityPack{id: "local", authority: :construct}} =
             CapabilityPack.load(@valid)

    assert {:ok, %CapabilityPack{properties: [:durable]}} =
             CapabilityPack.load(%{
               "id" => "x",
               "capabilities" => ["Work.Select"],
               "properties" => ["durable"]
             })

    assert {:ok, _} = CapabilityPack.load(Map.to_list(@valid))
  end

  test "validate accepts a built struct" do
    {:ok, p} = CapabilityPack.load(@valid)
    assert :ok = CapabilityPack.validate(p)
  end

  test "mutation: invalid capability refused" do
    assert {:error, %{reason: :invalid_capability, capability: "Nope.X"}} =
             CapabilityPack.load(%{@valid | capabilities: ["File.Read", "Nope.X"]})
  end

  test "mutation: empty and duplicate capabilities refused" do
    assert {:error, %{detail: :no_capabilities}} =
             CapabilityPack.load(%{@valid | capabilities: []})

    assert {:error, %{detail: :duplicate_capabilities}} =
             CapabilityPack.load(%{@valid | capabilities: ["File.Read", "File.Read"]})
  end

  test "mutation: authority above construct refused" do
    assert {:error, %{reason: :authority_ceiling, authority: :do}} =
             CapabilityPack.load(Map.put(@valid, :authority, :do))
  end

  test "mutation: malformed input refused" do
    assert {:error, %{reason: :invalid_pack}} =
             CapabilityPack.load(%{capabilities: ["File.Read"]})

    assert {:error, %{reason: :invalid_pack}} = CapabilityPack.load(:nope)
    assert {:error, %{reason: :invalid_pack}} = CapabilityPack.validate(%{})
  end

  test "SHACL shape and ontology declare the pack vocabulary" do
    shape = File.read!("ontology/capability_pack.ttl")
    onto = File.read!("ontology.ttl")
    assert shape =~ "ap:CapabilityPackShape"
    assert shape =~ ~s|sh:in ( "observe" "select" "construct" )|
    refute shape =~ ~s|"do"|

    for term <- ~w(Capability Realization ExecutionProperty Correspondence CapabilityPack) do
      assert onto =~ ~r/^ap:#{term} a rdfs:Class/m
    end
  end
end

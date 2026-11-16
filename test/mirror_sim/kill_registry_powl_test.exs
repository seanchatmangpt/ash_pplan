defmodule AshPPlan.MirrorSim.KillRegistryPowlTest do
  @moduledoc """
  Mutation-killing courts for PR-01..04, PW-01/03/04/05, FO-06, RC-07
  (see test/support/mirror_sim/mutants_runtime.ex).
  """
  use ExUnit.Case, async: false

  alias AshPPlan.FOND
  alias AshPPlan.POWL
  alias AshPPlan.Providers.Registry
  alias AshPPlan.RuntimeContract.AuthorityGate

  describe "providers registry" do
    test "PR-01: seal records the module and reason in the sealed map" do
      reg = Registry.new([ProvA, ProvB]) |> Registry.seal(ProvA, :boom)
      assert reg.sealed == %{ProvA => :boom}
    end

    test "PR-02: seal removes the module from active providers" do
      reg = Registry.new([ProvA, ProvB]) |> Registry.seal(ProvA, :boom)
      assert Registry.providers(reg) == [ProvB]
      assert reg.generation == 1
    end

    test "PR-03: registering an already-present module keeps providers unique" do
      reg = Registry.new([ProvA]) |> Registry.register(ProvA)
      assert Registry.providers(reg) == [ProvA]
    end

    test "PR-04: sealing a non-member is a no-op (no sealed entry, no generation bump)" do
      base = Registry.new([ProvA])
      reg = Registry.seal(base, ProvZ, :boom)
      assert reg == base
      assert reg.sealed == %{}
      assert reg.generation == 0
    end
  end

  describe "POWL" do
    test "PW-01: bare integer 0 endpoint normalizes to {:child, 0}" do
      node = POWL.choice_graph("cg", [POWL.activity("a")], [{:start, 0}, {0, :end}])
      assert node.edges == [{:start, {:child, 0}}, {{:child, 0}, :end}]
    end

    test "PW-03: order edges with a dangling endpoint are dropped" do
      plan = %{
        steps: [
          %{iri: "a", label: "a", predecessors: []},
          %{iri: "b", label: "b", predecessors: ["ghost", "a"]}
        ]
      }

      assert {:ok, node} = POWL.normalize(plan)
      assert node.order_edges == [{"a", "b"}]
    end

    test "PW-04: empty-steps catalog plan has root id po_empty" do
      assert {:ok, node} = POWL.normalize(%{steps: []})
      assert node.id == "po_empty"
    end

    test "PW-05: loop children are ordered [body, redo]" do
      node = POWL.loop("l", POWL.activity("body"), POWL.activity("redo"))
      assert Enum.map(node.children, & &1.id) == ["body", "redo"]
    end
  end

  describe "FOND" do
    test "FO-06: reachable non-goal state without a policy entry is :missing_policy_action" do
      {:ok, domain} = FOND.new(%{a: %{go: [:g]}}, [:g])

      assert {:error, %{reason: :missing_policy_action, state: :a}} =
               FOND.validate_policy(domain, %{}, :a, :strong)
    end
  end

  describe "runtime contract authority gate" do
    test "RC-07: input without an action key is refused as :missing_action" do
      assert AuthorityGate.authorize(%{}) == {:error, {:refused, :authority, :missing_action}}

      # Real behavior: an action key without a policy hits the second clause, which
      # echoes the action (not :missing_action). Only the third clause is mutated.
      assert AuthorityGate.authorize(%{action: "CONSTRUCT"}) ==
               {:error, {:refused, :authority, "CONSTRUCT"}}
    end
  end
end

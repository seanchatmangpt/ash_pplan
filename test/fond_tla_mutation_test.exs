defmodule AshPPlan.FONDTLAMutationTest do
  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.FOND.TLA.Mutation
  alias AshPPlan.Test.TLAReader

  test "mutation suite manufactures independent negative controls" do
    {:ok, domain} =
      FOND.new(%{pending: %{attempt: [:pending, :done]}, done: %{}}, [:done])

    {:ok, rendered} = FOND.to_tla(domain, %{pending: :attempt}, :pending, :strong_cyclic)
    mutants = Mutation.suite(rendered)

    assert Keyword.has_key?(mutants, :drop_goal_property)
    assert Keyword.has_key?(mutants, :weaken_strong_fairness)
    assert Keyword.has_key?(mutants, :stutter_first_tick)
    assert Keyword.has_key?(mutants, :drop_first_branch)
    assert Keyword.has_key?(mutants, :undefined_next_action)
  end

  test "weakening strong fairness changes retry semantics" do
    {:ok, domain} =
      FOND.new(%{pending: %{attempt: [:pending, :done]}, done: %{}}, [:done])

    {:ok, rendered} = FOND.to_tla(domain, %{pending: :attempt}, :pending, :strong_cyclic)
    assert TLAReader.check!(rendered).verdict == :admitted

    weakened = Mutation.suite(rendered) |> Keyword.fetch!(:weaken_strong_fairness)
    assert TLAReader.check!(weakened).verdict == :refused
  end
end

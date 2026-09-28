defmodule AshPPlan.FONDTLAMutationTest do
  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.FOND.TLA.Mutation
  alias AshPPlan.Test.TLAReader

  test "mutation suite manufactures independent negative controls" do
    {:ok, domain} =
      FOND.new(%{pending: %{attempt: [:pending, :done]}, done: %{}}, [:done])

    {:ok, rendered} =
      FOND.to_tla(domain, %{pending: :attempt}, :pending, :strong_cyclic)

    mutants = Mutation.suite(rendered)

    assert Keyword.has_key?(mutants, :drop_goal_property)
    assert Keyword.has_key?(mutants, :weaken_strong_fairness)
    assert Keyword.has_key?(mutants, :stutter_first_tick)
    assert Keyword.has_key?(mutants, :drop_first_branch)
    assert Keyword.has_key?(mutants, :undefined_next_action)
  end

  test "dropping an admitted branch is rejected by the independent reader" do
    {:ok, domain} =
      FOND.new(%{pending: %{attempt: [:pending, :done]}, done: %{}}, [:done])

    {:ok, rendered} =
      FOND.to_tla(domain, %{pending: :attempt}, :pending, :strong_cyclic)

    mutant = Mutation.suite(rendered) |> Keyword.fetch!(:drop_first_branch)

    assert_raise RuntimeError, fn ->
      TLAReader.check!(mutant)
    end
  end
end

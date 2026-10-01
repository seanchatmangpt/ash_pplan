defmodule AshPPlan.FOND.Supervision.ProviderChainTest do
  use ExUnit.Case, async: true
  alias AshPPlan.FOND.Supervision.ProviderChain

  defmodule Empty do
    def id, do: :empty
    def candidates(_, _), do: {:ok, []}
  end

  defmodule Good do
    def id, do: :good
    def candidates(_, _), do: {:ok, [:candidate]}
  end

  test "falls through empty provider" do
    assert {:ok, :good, [:candidate]} = ProviderChain.fetch([Empty, Good], :d, :i)
  end
end

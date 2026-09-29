defmodule AshPPlan.SA2A.ProviderTest do
  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.SA2A.Provider

  test "provider exposes the existing FOND planner without actuation" do
    {:ok, domain} = FOND.new(%{pending: %{finish: [:done]}, done: %{}}, [:done])

    assert {:ok,
            %{
              subject: "s",
              formalism: :fond,
              authority: :none,
              standing: :candidate
            }} =
             Provider.propose(
               %{subject: "s", formalism: :fond, domain: domain, initial: :pending},
               []
             )
  end

  test "unsupported formalism is refused" do
    assert {:error, %{code: :unsupported_formalism, detail: :hddl}} =
             Provider.propose(%{subject: "s", formalism: :hddl}, [])
  end
end

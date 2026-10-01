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

  test "provider exports the surface AshA2A.Replan.Port.AshPPlan consumes" do
    assert Code.ensure_loaded?(Provider)
    assert function_exported?(Provider, :supports?, 1)
    assert function_exported?(Provider, :propose, 2)

    for formalism <- [:fond, :powl, :hddl, :pddl, nil] do
      assert Provider.supports?(formalism) == (formalism in [:fond, :powl])
    end
  end

  test "malformed requests are refused without authority" do
    assert {:error, %{code: :missing_subject, authority: :none}} =
             Provider.propose(%{subject: nil, formalism: :fond}, [])

    assert {:error, %{code: :unsupported_formalism, detail: nil, authority: :none}} =
             Provider.propose(%{subject: "s"}, [])
  end

  test "an unsolvable FOND domain is a typed planner refusal" do
    {:ok, domain} = FOND.new(%{pending: %{}, done: %{}}, [:done])

    assert {:error, %{code: :planner_refused, authority: :none}} =
             Provider.propose(
               %{subject: "s", formalism: :fond, domain: domain, initial: :pending},
               []
             )
  end
end

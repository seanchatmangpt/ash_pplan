defmodule AshPPlan.FOND.Supervision.AuthorityGuardTest do
  use ExUnit.Case, async: true
  alias AshPPlan.FOND.Supervision.AuthorityGuard

  test "refuses authority-bearing metadata" do
    assert {:error, {:authority_bearing_policy, :authority}} =
             AuthorityGuard.check(%{authority: :root})

    assert :ok = AuthorityGuard.check(%{source: :planner})
  end
end

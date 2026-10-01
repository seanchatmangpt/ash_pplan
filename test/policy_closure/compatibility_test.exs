defmodule AshPPlan.PolicyClosure.CompatibilityTest do
  use ExUnit.Case, async: true
  alias AshPPlan.PolicyClosure.Compatibility

  test "source matters",
    do:
      refute(
        Compatibility.compatible?(%{schema: 1, source_sha: "a"}, %{schema: 1, source_sha: "b"})
      )
end

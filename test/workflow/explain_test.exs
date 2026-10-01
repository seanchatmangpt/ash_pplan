defmodule AshPPlan.Workflow.ExplainTest do
  use ExUnit.Case, async: true

  alias AshPPlan.Workflow.Runtime
  alias AshPPlan.Examples.UltraCode.Steps

  @frontier [%{id: :a, status: :open, deps: []}]

  test "explain a workflow answers provider, rejection, authority and evidence questions" do
    {:ok, e} = Runtime.explain(Steps.workflow(), providers: [Steps.Flaky, Steps.Local])
    assert e.what.workflow == "ultracode"
    assert e.providers[:execute].provider == Steps.Flaky
    assert e.authority == %{granted: [], ceiling: :construct, do_authority: false}
    assert e.failure.alternatives[:execute] == [Steps.Local]
    assert :receipt in e.evidence.required
  end

  test "explain a failed run names the sealed provider and the remaining alternative" do
    {:ok, s} =
      Runtime.run(Steps.workflow(), %{frontier: @frontier}, providers: [Steps.Flaky, Steps.Local])

    {:ok, e} = Runtime.explain(s)
    assert e.failure.observed == :failed
    assert e.failure.sealed == Steps.Flaky
    assert Map.has_key?(e.failure.sealed_registry, Steps.Flaky)
    assert e.failure.alternatives[:execute] == [Steps.Local]
  end

  test "explain surfaces an unresolved task instead of raising" do
    {:ok, e} = Runtime.explain(Steps.workflow(), providers: [])
    assert %{unresolved: %{reason: :no_qualified_provider}} = e.providers
  end
end

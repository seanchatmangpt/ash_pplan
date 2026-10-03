defmodule AshPPlan.Workflow.UltracodeTest do
  use ExUnit.Case, async: true

  alias AshPPlan.Workflow.Runtime
  alias AshPPlan.Examples.UltraCode.Steps

  test "plan -> resolve -> run -> observe -> explain with refusal fallback closes the frontier item" do
    frontier = [%{id: :a, status: :open, deps: []}, %{id: :b, status: :open, deps: [:a]}]

    assert {:ok, %{plan: plan}} = Runtime.plan(Steps.workflow())
    assert length(plan.steps) == 5

    assert {:ok, %{bindings: b}} =
             Runtime.resolve(Steps.workflow(), providers: [Steps.Flaky, Steps.Local])

    assert b[:execute].provider == :ultracode_flaky

    {:ok, failed} =
      Runtime.run(Steps.workflow(), %{frontier: frontier}, providers: [Steps.Flaky, Steps.Local])

    assert failed.observation.transition.to == :failed

    {:ok, done} = Runtime.resume(failed)
    assert {:ok, %{verified: true, closed: :a, executor: :steady}} = done.outcome

    {:ok, why} = Runtime.explain(done)
    assert why.failure.observed == :succeeded
    assert Map.has_key?(why.failure.sealed_registry, Steps.Flaky)
  end

  test "the generated module path is used when present" do
    mod = AshPPlan.Examples.Workflows.Ultracode

    if Code.ensure_loaded?(mod) do
      assert {:ok, %{subject: %{workflow: "ultracode"}}} = Runtime.plan(mod)
    else
      assert {:error, %{reason: :unknown_workflow}} = Runtime.plan(mod)
    end
  end
end

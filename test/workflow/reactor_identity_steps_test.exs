defmodule AshPPlan.Workflow.ReactorIdentityStepsTest do
  @moduledoc """
  Court: the step IRI (`Subject.correspondence/2` `:reactor`) is the one step name.
  Every step of every projected generated workflow, enriched with `verify: true`,
  carries the identity of its own task. Anti-vacuity: a step renamed to its bare task
  id is not stamped and the projection is refused as diverging; at least one generated
  workflow must actually project.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Test.Examples.ProviderIndex
  alias AshPPlan.Providers.Registry
  alias AshPPlan.Workflow.{Model, Subject}
  alias AshPPlan.Workflow.Project

  @workflows [
    AshPPlan.Examples.Workflows.FileRelease,
    AshPPlan.Examples.Workflows.QualifiedFulfillment,
    AshPPlan.Examples.Workflows.Ultracode
  ]

  defp projected do
    reg = Registry.new(ProviderIndex.modules())

    for wf <- @workflows,
        m = wf.model(),
        resolved =
          Enum.map(m.tasks, &{&1.id, Registry.resolve(reg, %{capability: &1.capability})}),
        Enum.all?(resolved, fn {_, r} -> match?({:ok, _}, r) end),
        bindings = Map.new(resolved, fn {id, {:ok, r}} -> {id, r.realization} end),
        {:ok, reactor} <- [Project.Reactor.project(m, bindings)] do
      {m, reactor}
    end
  end

  test "every step of every projected generated workflow carries its own task identity" do
    projections = projected()
    assert projections != [], "no generated workflow projected: court would be vacuous"

    for {%Model{} = m, reactor} <- projections do
      assert {:ok, enriched} = AshPPlan.Reactor.enrich(reactor, m)
      corr = Subject.bind(m).correspondence
      key = AshPPlan.Reactor.context_key()

      for t <- m.tasks do
        step = Enum.find(enriched.steps, &(to_string(&1.name) == corr[t.id].reactor))
        assert step, "#{m.name}: no step for #{t.id}"
        assert step.context[key].task == to_string(t.id)
      end
    end
  end

  test "anti-vacuity: a bare-task-id step name is refused" do
    [{m, r} | _] = projected()
    renamed = %{r | steps: Enum.map(r.steps, &%{&1 | name: "observe"})}
    assert {:error, %{reason: :projection_diverges}} = AshPPlan.Reactor.enrich(renamed, m)
  end
end

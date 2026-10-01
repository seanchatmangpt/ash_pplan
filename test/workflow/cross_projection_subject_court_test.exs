defmodule AshPPlan.Workflow.CrossProjectionSubjectCourtTest do
  @moduledoc """
  Same Subject Court across the projections of every generated workflow: P-PLAN (iri), HDDL
  (`t_<task>`), FOND (action key) and, once `AshPPlan.Reactor.step_for/1` is wired, Reactor
  (step names via `Project.Reactor.project`) must each carry exactly the correspondence id
  `Subject.bind/1` derives per task: no extra, no missing. Anti-vacuity mutation: swapping one
  task id inside a projection is reported as drift.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Workflow.{Model, Subject}
  alias AshPPlan.Workflow.Project.{FOND, HDDL, PPlan}

  @workflows [AshPPlan.Generated.Workflows.Ultracode, AshPPlan.Generated.Workflows.FileRelease]

  defp fond_ids(model) do
    {:ok, fond} = FOND.project(model)

    Map.get(fond, :domain, fond).transitions
    |> Map.values()
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.map(fn
      {:run, t} -> to_string(t)
      a -> to_string(a)
    end)
    |> Enum.uniq()
  end

  defp pplan_ids(model), do: for(s <- PPlan.project(model).steps, do: s.iri)

  defp hddl_ids(model),
    do: ~r/\bt_[A-Za-z0-9_\-]+/ |> Regex.scan(HDDL.render(model)) |> List.flatten() |> Enum.uniq()

  for wf <- @workflows do
    test "#{inspect(wf)}: every projection carries exactly the correspondence ids" do
      model = unquote(wf).model()
      assert :ok = Model.validate(model)
      subject = Subject.bind(model)
      assert map_size(subject.correspondence) == length(model.tasks)
      assert subject.id == unquote(wf).subject().id

      for t <- model.tasks do
        c = Map.fetch!(subject.correspondence, t.id)
        assert c.pplan in pplan_ids(model)
        assert c.hddl in hddl_ids(model)
        assert c.fond in fond_ids(model)
      end

      for {kind, ids} <- [pplan: pplan_ids(model), fond: fond_ids(model)] do
        expected = for {_, c} <- subject.correspondence, do: Map.fetch!(c, kind)
        assert Enum.sort(ids) == Enum.sort(expected), "#{kind} not exactly the correspondence"
        assert :ok = Subject.verify_correspondence(model, kind, ids)
      end

      assert :ok = Subject.verify_correspondence(model, :hddl, HDDL.render(model))
      assert :ok = Subject.verify_projection(model, :pplan, PPlan.project(model))
      assert :ok = Subject.verify_projection(model, :hddl, HDDL.render(model))
      assert {:ok, fond} = FOND.project(model)
      assert :ok = Subject.verify_projection(model, :fond, fond)
    end
  end

  test "mutation: swapping one task id in a projection is reported as drift" do
    for wf <- @workflows do
      model = wf.model()
      [first | rest] = ids = pplan_ids(model)
      swapped = [first <> "-swapped" | rest]
      assert ids != swapped

      assert {:error, %{missing: [^first], extra: [extra], drift: [{^first, extra}]}} =
               Subject.verify_correspondence(model, :pplan, swapped)

      assert extra == first <> "-swapped"
    end
  end

  test "mutation: dropping or adding a task is reported as missing or extra" do
    model = AshPPlan.Generated.Workflows.Ultracode.model()
    ids = fond_ids(model)

    assert {:error, %{missing: [_], extra: []}} =
             Subject.verify_correspondence(model, :fond, tl(ids))

    assert {:error, %{missing: [], extra: ["ghost"]}} =
             Subject.verify_correspondence(model, :fond, ["ghost" | ids])

    mutated = %{model | tasks: Enum.drop(model.tasks, -1)}
    refute Subject.bind(model).id == Subject.bind(mutated).id
    assert {:error, _} = Subject.verify_projection(model, :pplan, PPlan.project(mutated))
  end

  test "reactor projection carries the correspondence once step_for is wired" do
    if Code.ensure_loaded?(AshPPlan.Reactor) and
         function_exported?(AshPPlan.Reactor, :step_for, 1) do
      alias AshPPlan.Workflow.Project.Reactor, as: RProj
      model = AshPPlan.Generated.Workflows.FileRelease.model()
      bindings = reactor_bindings(model)

      if bindings do
        assert {:ok, reactor} = RProj.project(model, bindings)
        names = for s <- reactor.steps, do: to_string(s.name)
        expected = for t <- model.tasks, do: to_string(RProj.step_iri(model, t.id))
        assert Enum.sort(names) == Enum.sort(expected)
      end
    end
  end

  defp reactor_bindings(model) do
    reg = AshPPlan.Providers.Registry.new(AshPPlan.Test.Examples.ProviderIndex.modules())

    results =
      for t <- model.tasks do
        {t.id, AshPPlan.Providers.Registry.resolve(reg, %{capability: t.capability})}
      end

    if Enum.all?(results, &match?({_, {:ok, _}}, &1)),
      do: Map.new(results, fn {id, {:ok, r}} -> {id, r.realization} end)
  end
end

defmodule AshPPlan.Workflow.DynamicInheritanceCourtTest do
  @moduledoc """
  Dynamic Inheritance Court: steps created at run time inherit the parent's
  semantic identity (subject, workflow, capability, properties) and can never
  exceed the parent's authority ceiling. Anti-vacuity: an escalating child and
  an identity-less parent are refused; the inherited identity differs from a
  fresh one in task and IRI.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Workflow.{Model, Subject}

  defmodule Spawn do
    @moduledoc false
    use Reactor.Step

    @impl true
    def run(_arguments, context, _options) do
      parent = Map.fetch!(context, :ash_pplan_workflow)

      {:ok, child} =
        AshPPlan.Reactor.inherit(parent, Reactor.Builder.new_step!(:child, __MODULE__.Leaf, []))

      {:ok, child.context.ash_pplan_workflow}
    end
  end

  defmodule Spawn.Leaf do
    @moduledoc false
    use Reactor.Step

    @impl true
    def run(_a, context, _o), do: {:ok, context.ash_pplan_workflow}
  end

  defp enriched do
    {:ok, model} =
      Model.new(
        name: "dyn",
        tasks: [[id: :fan, capability: "File.Read", properties: ["durable"], authority: :plan]]
      )

    {:ok, r} = Reactor.Builder.add_step(Reactor.Builder.new(), :fan, Spawn, [])
    {:ok, r} = Reactor.Builder.return(r, :fan)
    {:ok, r} = AshPPlan.Reactor.enrich(r, model)
    {model, r}
  end

  test "a dynamic step inherits subject, capability, properties and ceiling" do
    {model, r} = enriched()
    subject = Subject.bind(model)

    assert {:ok, child} = Reactor.run(r, %{}, %{run_id: "dyn-1"})
    assert child.subject == subject.id
    assert child.workflow == "dyn"
    assert child.task == "fan/child"
    assert child.parent == "fan"
    assert child.capability == "File.Read"
    assert child.properties == ["durable"]
    assert child.authority == :plan
    assert child.iri == subject.correspondence[:fan].semantic <> "/child"
  end

  test "inherit works on a list and from a Reactor.Step parent" do
    {_model, r} = enriched()
    [parent] = r.steps
    kids = for n <- [:a, :b], do: Reactor.Builder.new_step!(n, Spawn.Leaf, [])

    assert {:ok, [a, b]} = AshPPlan.Reactor.inherit(parent, kids)
    assert AshPPlan.Reactor.identity_of(a).task == "fan/a"
    assert AshPPlan.Reactor.identity_of(b).task == "fan/b"
  end

  test "a child asking for more authority than its parent is refused" do
    {_model, r} = enriched()
    [parent] = r.steps

    greedy =
      Reactor.Builder.new_step!(:greedy, Spawn.Leaf, [],
        context: %{ash_pplan_workflow: %{authority: :construct}}
      )

    assert {:error, %{reason: :authority_escalation, ceiling: :plan, requested: :construct}} =
             AshPPlan.Reactor.inherit(parent, greedy)

    wild =
      Reactor.Builder.new_step!(:wild, Spawn.Leaf, [],
        context: %{ash_pplan_workflow: %{authority: :do}}
      )

    assert {:error, %{reason: :unknown_authority, authority: :do}} =
             AshPPlan.Reactor.inherit(parent, wild)
  end

  test "a child may narrow authority" do
    {_model, r} = enriched()
    [parent] = r.steps

    narrow =
      Reactor.Builder.new_step!(:narrow, Spawn.Leaf, [],
        context: %{ash_pplan_workflow: %{authority: :observe}}
      )

    assert {:ok, s} = AshPPlan.Reactor.inherit(parent, narrow)
    assert AshPPlan.Reactor.identity_of(s).authority == :observe
  end

  test "a parent without identity yields no inheritance (anti-vacuity)" do
    bare = Reactor.Builder.new_step!(:bare, Spawn.Leaf, [])

    assert {:error, %{reason: :parent_without_identity}} =
             AshPPlan.Reactor.inherit(bare, Reactor.Builder.new_step!(:kid, Spawn.Leaf, []))
  end
end

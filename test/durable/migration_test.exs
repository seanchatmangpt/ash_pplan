defmodule AshPPlan.Reactor.Durable.MigrationTest do
  @moduledoc """
  Court: `Migration` over the real `Store.Ets`, real Reactor and the real engine.

  A parked run's workflow is renamed through subject correspondence and the run is driven to
  completion; the effect counters (an `Effects` agent outside every runner) prove the renamed
  step replayed instead of running again. Also: idempotent apply, the ledger entry in the run
  context, and the `ProcessEvidence` events / OCEL2 export of the migration.

  Anti-vacuity mutations: make `rekey!/4` skip the `record` call -> "rename replays" fails
  (observe runs twice); drop the `:migrations` update in `switch/7` -> the ledger test fails;
  make `do_apply/5` ignore `current == plan.new_subject` -> the idempotence test fails.
  """
  use ExUnit.Case, async: false

  Code.require_file("lane_b_fixture.exs", __DIR__)

  alias AshPPlan.Durable.LaneBFx
  alias AshPPlan.ProcessEvidence
  alias AshPPlan.Reactor.Durable.{Clock, Engine, Migration, Testing}
  alias AshPPlan.Reactor.Durable.Store.Ets

  setup do
    LaneBFx.install_adapter!()
    Clock.use_test_clock()
    on_exit(&Clock.reset/0)
    name = :"mig_fx_#{System.unique_integer([:positive])}"
    {:ok, _} = AshPPlan.Test.Effects.start_link(name: name)
    {:ok, store} = Ets.start_link()
    {:ok, store: store, fx: name}
  end

  # The linear model with `observe` renamed to `observe_frontier`.
  defp renamed_model, do: LaneBFx.renamed_model()

  defp parked(store, fx, id) do
    {:ok, _} = Engine.start(store, LaneBFx.attrs(id, fx, kinds: %{integrate: :await}))
    assert {:parked, :waiting} = Engine.attempt(store, id)
    assert LaneBFx.counts(fx) == %{observe: 1, select: 1, execute: 1}
  end

  defp plan!(old, new, opts) do
    assert {:ok, plan} = Migration.plan(old, new, opts)
    plan
  end

  test "plan maps renamed tasks through subject correspondence" do
    plan = plan!(LaneBFx.model(:linear), renamed_model(), renames: %{observe: :observe_frontier})

    assert plan.mapping[:observe] == :observe_frontier
    assert plan.mapping[:select] == :select
    assert plan.renames == %{observe: :observe_frontier}
    assert plan.removed == [] and plan.added == []
    assert plan.old_subject != plan.new_subject
    step = Enum.find(plan.steps, &(&1.old_task == :observe))
    assert step.new_key == AshPPlan.Reactor.Durable.Key.for_name(step.new_name)
    assert step.new_key != step.old_key
  end

  test "a renamed step replays instead of re-running", %{store: store, fx: fx} do
    parked(store, fx, "r1")
    plan = plan!(LaneBFx.model(:linear), renamed_model(), renames: %{observe: :observe_frontier})

    assert {:ok, %{status: :migrated, entry: entry}} = Migration.apply(store, "r1", plan)
    assert [%{task: :observe, to_task: :observe_frontier}] = entry.rekeyed

    run = Engine.fetch(store, "r1")
    assert run.status == :waiting
    assert Enum.any?(run.model.tasks, &(&1.id == :observe_frontier))
    assert Enum.any?(Testing.tape(store, "r1"), &String.ends_with?(&1, "step-observe_frontier\""))
    refute Enum.any?(Testing.tape(store, "r1"), &String.ends_with?(&1, "step-observe\""))

    {:ok, _} = Engine.signal(store, "r1", "go", :now)
    assert [{"r1", {:completed, _}}] = Testing.drain(store)
    assert LaneBFx.counts(fx) == %{observe: 1, select: 1, execute: 1, verify: 1}
  end

  test "apply is idempotent", %{store: store, fx: fx} do
    parked(store, fx, "i1")
    plan = plan!(LaneBFx.model(:linear), renamed_model(), renames: %{observe: :observe_frontier})

    assert {:ok, %{status: :migrated}} = Migration.apply(store, "i1", plan)
    before = Engine.fetch(store, "i1")
    tape = Testing.tape(store, "i1")

    assert {:ok, %{status: :already_applied, entry: %{to: to}}} =
             Migration.apply(store, "i1", plan)

    assert to == plan.new_subject

    again = Engine.fetch(store, "i1")
    assert again.model == before.model and again.bindings == before.bindings
    assert again.context == before.context
    assert length(again.context.migrations) == 1
    assert Testing.tape(store, "i1") == tape
  end

  test "migration is recorded in the ledger and in process evidence", %{store: store, fx: fx} do
    parked(store, fx, "e1")
    plan = plan!(LaneBFx.model(:linear), renamed_model(), renames: %{observe: :observe_frontier})
    {:ok, _} = Migration.apply(store, "e1", plan)

    run = Engine.fetch(store, "e1")

    assert [%{from: from, to: to, renames: %{observe: :observe_frontier}}] =
             run.context.migrations

    assert from == plan.old_subject and to == plan.new_subject

    events = Migration.evidence(run)
    assert Enum.map(events, & &1.activity) == ["workflow_migrated", "task_rekeyed"]
    assert Enum.all?(events, &(&1.subject_id == plan.new_subject))

    assert {:ok, json} = ProcessEvidence.export(events, :ocel2_json)
    assert json =~ "workflow_migrated" and json =~ "task_rekeyed"
    assert json =~ plan.new_subject
  end
end

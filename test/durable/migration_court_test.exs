defmodule AshPPlan.Reactor.Durable.MigrationCourtTest do
  @moduledoc """
  Adversarial court for `Migration`: every change that would orphan a standing checkpoint is
  refused with the list of orphans and writes nothing; terminal and running runs are refused;
  `compensate: true` admits the change and takes the orphan back through the step's own undo.

  Anti-vacuity mutations: make `classify/3` return `{:ok, rekey, []}` -> the refusal tests
  fail; make `check_status/1` accept `:completed` -> the terminal test fails; replace the
  `claim` in `claim_and_apply/5` with a plain `get_run` -> the running-run test fails; skip
  `compensate_orphans/4` -> the undo counter stays 0 and the compensate test fails. The control
  test swaps the model WITHOUT the migration and shows `observe` running twice, so the effect
  counters can tell replay from re-run.
  """
  use ExUnit.Case, async: false

  Code.require_file("lane_b_fixture.exs", __DIR__)

  alias AshPPlan.Durable.LaneBFx
  alias AshPPlan.Reactor.Durable.{Clock, Engine, Migration, Testing}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Test.Effects
  alias AshPPlan.Workflow.Model

  setup do
    LaneBFx.install_adapter!()
    Clock.use_test_clock()
    on_exit(&Clock.reset/0)
    name = :"migc_fx_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: name)
    {:ok, store} = Ets.start_link()
    {:ok, store: store, fx: name}
  end

  # The linear model with `edit.(task_map)` applied to each task (nil drops the task).
  defp variant(edit) do
    old = LaneBFx.model(:linear)

    tasks =
      old.tasks
      |> Enum.map(&Map.from_struct/1)
      |> Enum.map(edit)
      |> Enum.reject(&is_nil/1)

    {:ok, m} = Model.new(name: old.name, goal: old.goal, tasks: tasks)
    m
  end

  defp without_select do
    variant(fn
      %{id: :select} -> nil
      %{id: :execute} = t -> %{t | depends_on: [:observe]}
      t -> t
    end)
  end

  defp parked(store, fx, id, kinds \\ %{}) do
    {:ok, _} =
      Engine.start(store, LaneBFx.attrs(id, fx, kinds: Map.put(kinds, :integrate, :await)))

    assert {:parked, :waiting} = Engine.attempt(store, id)
  end

  # A refused apply may bump claim bookkeeping (version/claim fields); the run's content is what must not move.
  defp core(run), do: Map.take(run, [:model, :bindings, :context, :status, :inputs, :result])

  defp plan!(new, opts \\ []) do
    assert {:ok, plan} = Migration.plan(LaneBFx.model(:linear), new, opts)
    plan
  end

  test "a removed task with a standing checkpoint is refused, listing the orphan", %{
    store: store,
    fx: fx
  } do
    parked(store, fx, "d1")
    before = core(Engine.fetch(store, "d1"))

    assert {:error, %{reason: :orphaned_checkpoints, orphaned: orphaned}} =
             Migration.apply(store, "d1", plan!(without_select()))

    # execute depended on select, so dropping select also changes execute's dependencies.
    assert [:select, :execute] = Enum.map(orphaned, & &1.task)
    assert %{cause: :task_removed, label: label} = hd(orphaned)
    assert label =~ "step-select"
    assert %{cause: :dependencies_changed} = List.last(orphaned)
    assert core(Engine.fetch(store, "d1")) == before
    assert length(Testing.tape(store, "d1")) == 3
  end

  test "a changed capability of a completed task is refused", %{store: store, fx: fx} do
    parked(store, fx, "c1")

    new =
      variant(fn
        %{id: :execute} = t -> %{t | capability: "Work.Select"}
        t -> t
      end)

    assert {:error,
            %{
              reason: :orphaned_checkpoints,
              orphaned: [%{task: :execute, cause: :capability_changed}]
            }} =
             Migration.apply(store, "c1", plan!(new))
  end

  test "a changed dependency order of a completed task is refused", %{store: store, fx: fx} do
    parked(store, fx, "o1")

    new =
      variant(fn
        %{id: :execute} = t -> %{t | depends_on: [:observe]}
        t -> t
      end)

    assert {:error,
            %{
              reason: :orphaned_checkpoints,
              orphaned: [%{task: :execute, cause: :dependencies_changed}]
            }} =
             Migration.apply(store, "o1", plan!(new))
  end

  test "compensate: true admits the change and takes the orphan back through its undo", %{
    store: store,
    fx: fx
  } do
    parked(store, fx, "m1", %{select: :undo})
    assert Effects.count(fx, {:undo, :select}) == 0

    assert {:ok, %{status: :migrated, entry: entry}} =
             Migration.apply(store, "m1", plan!(without_select(), compensate: true))

    assert [select_label, execute_label] = entry.compensated
    assert select_label =~ "step-select" and execute_label =~ "step-execute"
    assert Effects.count(fx, {:undo, :select}) == 1
    refute Enum.any?(Testing.tape(store, "m1"), &(&1 =~ "step-select"))
    assert Testing.tape(store, "m1") |> Enum.any?(&(&1 =~ "step-observe"))

    {:ok, _} = Engine.signal(store, "m1", "go", :now)
    assert [{"m1", {:completed, _}}] = Testing.drain(store)
    assert Effects.count(fx, :observe) == 1
    assert Effects.count(fx, :select) == 1
    assert Effects.count(fx, :execute) == 2
  end

  test "terminal runs are refused", %{store: store, fx: fx} do
    {:ok, _} = Engine.start(store, LaneBFx.attrs("t1", fx))
    assert {:completed, _} = Engine.attempt(store, "t1")

    assert {:error, %{reason: :run_terminal, status: :completed}} =
             Migration.apply(store, "t1", plan!(without_select()))
  end

  test "a running (claimed) run is refused and left untouched", %{store: store, fx: fx} do
    parked(store, fx, "k1")
    {:ok, _} = Ets.claim(store, "k1", "worker-1", 30_000, Clock.now())
    version = Engine.fetch(store, "k1").version

    assert {:error, %{reason: :run_running}} =
             Migration.apply(store, "k1", plan!(without_select(), compensate: true))

    assert Engine.fetch(store, "k1").version == version
  end

  test "a run of another subject and an unknown run are refused", %{store: store, fx: fx} do
    parked(store, fx, "s1")

    other =
      variant(fn
        %{id: :verify} = t -> %{t | capability: "Work.Select"}
        t -> t
      end)

    assert {:ok, to_other} = Migration.plan(other, without_select())

    assert {:error, %{reason: :subject_mismatch}} = Migration.apply(store, "s1", to_other)
    assert {:error, %{reason: :no_such_run}} = Migration.apply(store, "nope", to_other)
  end

  test "a new model that cannot be projected writes nothing", %{store: store, fx: fx} do
    parked(store, fx, "u1")

    new =
      variant(fn
        t -> t
      end)

    added =
      new.tasks
      |> Enum.map(&Map.from_struct/1)
      |> Kernel.++([%{id: :extra, capability: "Work.Select", depends_on: [:verify]}])

    {:ok, grown} = Model.new(name: new.name, goal: new.goal, tasks: added)
    before = core(Engine.fetch(store, "u1"))

    assert {:error, %{reason: :new_model_unprojectable}} =
             Migration.apply(store, "u1", plan!(grown))

    assert core(Engine.fetch(store, "u1")) == before
  end

  test "plan refuses bad renames" do
    old = LaneBFx.model(:linear)

    assert {:error, %{reason: :unknown_rename_source}} =
             Migration.plan(old, old, renames: %{nope: :observe})

    assert {:error, %{reason: :unknown_rename_target}} =
             Migration.plan(old, old, renames: %{observe: :nope})

    assert {:error, %{reason: :ambiguous_rename}} =
             Migration.plan(old, old, renames: %{observe: :select})
  end

  test "control: swapping the model without the migration re-runs the renamed step", %{
    store: store,
    fx: fx
  } do
    parked(store, fx, "x1")

    plan =
      plan!(
        variant(fn
          %{id: :observe} = t -> %{t | id: :observe_frontier}
          %{id: :select} = t -> %{t | depends_on: [:observe_frontier]}
          t -> t
        end),
        renames: %{observe: :observe_frontier}
      )

    old = Engine.fetch(store, "x1").bindings

    bindings =
      old |> Map.delete(:observe) |> Map.put(:observe_frontier, Map.fetch!(old, :observe))

    {:ok, _} =
      Ets.transition(store, "x1", [:waiting], :waiting, %{
        model: plan.new_model,
        bindings: bindings
      })

    {:ok, _} = Engine.signal(store, "x1", "go", :now)
    Testing.drain(store)

    assert Effects.count(fx, :observe) == 2
  end
end

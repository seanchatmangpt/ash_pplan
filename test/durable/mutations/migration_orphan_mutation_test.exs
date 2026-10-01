defmodule AshPPlan.Reactor.Durable.Mutations.MigrationOrphanMutationTest do
  @moduledoc """
  Anti-vacuity mutation for the `Migration` orphan-refusal court
  (`test/durable/migration_court_test.exs`).

  Production property under test: `Migration.apply/4` refuses a migration that would orphan a
  standing checkpoint on a live parked run, with
  `{:error, %{reason: :orphaned_checkpoints, ...}}`, leaving the run content untouched.

  Mutation: compile a copy of the production `Migration` source with `classify/3`'s final guard
  removed, so orphaned checkpoints are admitted even when `compensate` is false, under the module
  name `Mutation.Migration`. The same property is run against BOTH modules: production refuses,
  the mutated copy admits — so the court's `{:error, :orphaned_checkpoints}` assertion is
  non-vacuous.

  No mocks: the real `Store.Ets`, real `Engine`, real lane-B fixture, and the mutated module is
  the production source itself with one mechanical break.
  """
  use ExUnit.Case, async: false

  Code.require_file("lane_b_fixture.exs", Path.expand("..", __DIR__))

  alias AshPPlan.Durable.LaneBFx
  alias AshPPlan.Reactor.Durable.{Clock, Engine, Migration}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Test.Effects
  alias AshPPlan.Workflow.Model

  @source_path "lib/ash_pplan/reactor/durable/migration.ex"

  setup do
    LaneBFx.install_adapter!()
    Clock.use_test_clock()
    on_exit(&Clock.reset/0)
    fx = :"mut_fx_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: fx)
    {:ok, store} = Ets.start_link()
    {:ok, store: store, fx: fx}
  end

  defp compile_mutated! do
    source = File.read!(Path.join(File.cwd!(), @source_path))

    mutated =
      source
      # Rename only the main module (the `Migration.Plan` sub-module keeps its name, so the
      # mutated apply/4 still accepts a plan produced by the production `Migration.plan/3`).
      |> String.replace(
        "defmodule AshPPlan.Reactor.Durable.Migration do",
        "defmodule AshPPlan.Reactor.Durable.Mutation.Migration do"
      )
      # Mechanical break: the orphan refusal branch can never fire.
      |> String.replace("and not compensate,", "and false,")

    assert mutated != source
    Code.compile_string(mutated)
  end

  # The exact property the migration court asserts on a live parked run.
  defp property(mod, store, fx) do
    id = "mut_#{Integer.to_string(System.unique_integer([:positive]))}"

    {:ok, _} = Engine.start(store, LaneBFx.attrs(id, fx, kinds: %{integrate: :await}))
    assert {:parked, :waiting} = Engine.attempt(store, id)

    old = LaneBFx.model(:linear)

    without_select =
      old.tasks
      |> Enum.map(&Map.from_struct/1)
      |> Enum.map(fn
        %{id: :select} -> nil
        %{id: :execute} = t -> %{t | depends_on: [:observe]}
        t -> t
      end)
      |> Enum.reject(&is_nil/1)

    {:ok, new} = Model.new(name: old.name, goal: old.goal, tasks: without_select)
    {:ok, plan} = Migration.plan(LaneBFx.model(:linear), new)

    mod.apply(store, id, plan)
  end

  test "control: production Migration refuses the orphaning migration", %{store: store, fx: fx} do
    Code.put_compiler_option(:ignore_module_conflict, true)

    result = property(Migration, store, fx)

    assert {:error, %{reason: :orphaned_checkpoints, orphaned: orphans}} = result
    assert [:select, :execute] = Enum.map(orphans, & &1.task)
  end

  test "MUTATION (orphan refusal removed): the same migration is admitted and the court assertion is violated",
       %{
         store: store,
         fx: fx
       } do
    Code.put_compiler_option(:ignore_module_conflict, true)
    compile_mutated!()
    mod = AshPPlan.Reactor.Durable.Mutation.Migration

    result = property(mod, store, fx)

    assert {:ok, _} = result,
           "the mutated classify/3 must no longer refuse: #{inspect(result)}"
  end
end

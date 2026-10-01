defmodule AshPPlan.Reactor.Durable.Mutations.CounterfactualDigestMutationTest do
  @moduledoc """
  Anti-vacuity mutation for the counterfactual digest-untouched court
  (`test/durable/counterfactual_test.exs`).

  Production property under test: `Counterfactual.replay/3` never mutates the original ledger —
  the `ledger_digest/3` of the original run is equal before and after every replay and the result
  reports `untouched?: true`.

  Mutation: compile a copy of the production `Counterfactual` source with `do_replay/5` bound to
  the ORIGINAL store instead of a scratch store (the replay then records checkpoints into and
  attempts against the original ledger), under the module name `Mutation.Counterfactual`. The
  digest-untouched property is run against BOTH modules: production reports `untouched?: true`,
  the mutated copy reports `untouched?: false` — so the court's untouched assertion is
  non-vacuous.

  No mocks: real `Store.Ets`, real `Engine`, real Reactor, real counting effects; the mutated
  module is the production source with one mechanical break.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.{Clock, Counterfactual, Engine}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Test.{DurableFx, Effects}

  @source_path "lib/ash_pplan/reactor/durable/counterfactual.ex"

  setup do
    DurableFx.install_adapter!()
    Clock.use_test_clock()
    on_exit(&Clock.reset/0)

    effects = :"cfmut_effects_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: effects)
    {:ok, store} = Ets.start_link()
    {:ok, store: store, effects: effects}
  end

  defp compile_mutated! do
    source = File.read!(Path.join(File.cwd!(), @source_path))

    # Mechanical break: replay uses the original store as its own scratch, mutating the ledger.
    mutated =
      source
      |> String.replace(
        "AshPPlan.Reactor.Durable.Counterfactual",
        "AshPPlan.Reactor.Durable.Mutation.Counterfactual"
      )
      |> String.replace(
        "{scratch, owned?} = scratch_store(opts)",
        "{scratch, owned?} = {store, false}"
      )

    assert mutated != source, "the mutation needle no longer matches the production source"

    Code.compile_string(mutated)
  end

  # Run one real durable run to completion (park on the human-release await, release, finish).
  defp completed_run(store, effects) do
    id = "cfmut_#{System.unique_integer([:positive])}"

    {:ok, _} = Engine.start(store, DurableFx.attrs(id, effects: effects))
    assert {:parked, _} = Engine.attempt(store, id)
    {:ok, _} = Engine.signal(store, id, DurableFx.signal_name(), %{released: true})
    result = Engine.attempt(store, id)
    assert match?({:completed, _}, result), "expected completion, got: #{inspect(result)}"

    id
  end

  test "control: production replay leaves the original ledger untouched", %{
    store: store,
    effects: effects
  } do
    Code.put_compiler_option(:ignore_module_conflict, true)
    id = completed_run(store, effects)

    assert {:ok, %{untouched?: true}} = Counterfactual.replay(store, id, change: %{})
  end

  test "MUTATION (replay against the original store): the original ledger is mutated", %{
    store: store,
    effects: effects
  } do
    Code.put_compiler_option(:ignore_module_conflict, true)
    compile_mutated!()
    mod = AshPPlan.Reactor.Durable.Mutation.Counterfactual

    id = completed_run(store, effects)

    assert {:ok, %{untouched?: untouched}} = mod.replay(store, id, change: %{})
    refute untouched, "the mutated replay must touch the original ledger"
  end
end

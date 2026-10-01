defmodule AshPPlan.Workflow.ExplainCounterfactualTest do
  @moduledoc """
  Court: `Explain.run/1` carries a counterfactual section for a durable run: the lawful
  alternative providers ("what if provider B had been used") and, when the run state requests a
  change under `:counterfactual`, the replayed consequence from the ledger.

  Real `Runtime`, real `Store.Ets`, real Reactor (cheap `Flaky` provider fails, `Local` is the
  alternative). Asserts: without a requested change `replayed` is nil and the alternatives are
  listed; with `provider: %{execute: Steps.Local}` the failed run is replayed to completion, the
  re-executed set is the `execute` cone, and the original ledger digest is unchanged; a refused
  change is reported as data; an in-process (non-durable) run reports no replay.

  Anti-vacuity: replaying with the failing provider unchanged keeps the outcome failed (an
  outcome-flip assertion that always passed would not distinguish the two).
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Examples.UltraCode.Steps
  alias AshPPlan.Reactor.Durable.{Clock, Counterfactual}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Workflow.{Explain, Runtime}

  @frontier [%{id: :a, status: :open, deps: []}]

  setup do
    Clock.use_test_clock()
    on_exit(&Clock.reset/0)
    {:ok, store} = Ets.start_link()

    {:ok, state} =
      Runtime.run(Steps.workflow(), %{frontier: @frontier},
        providers: [Steps.Flaky, Steps.Local],
        store: store,
        run_id: "ec-1"
      )

    {:ok, store: store, state: state}
  end

  test "section lists alternatives and no replay unless a change is requested", %{state: state} do
    assert state.observation.state == :failed
    {:ok, e} = Runtime.explain(state)
    assert e.counterfactual.what_if[:execute] == [Steps.Local]
    assert e.counterfactual.replayed == nil
  end

  test "what if provider B had been used: replayed from the ledger", %{store: store, state: state} do
    before = Counterfactual.ledger_digest(store, "ec-1")
    change = %{provider: %{execute: Steps.Local}}
    {:ok, e} = Runtime.explain(Map.put(state, :counterfactual, change))

    r = e.counterfactual.replayed
    assert r.change == change
    assert r.original_outcome == :failed
    assert r.counterfactual_outcome == :completed
    assert :execute in r.tasks_reexecuted
    assert r.original_untouched
    assert r.diff.outcome.changed?
    refute r.diff.empty?
    assert Counterfactual.ledger_digest(store, "ec-1") == before
    # the explained run itself still reports the failure it observed
    assert e.failure.observed == :failed
  end

  test "anti-vacuity: the failing provider again stays failed", %{state: state} do
    change = %{provider: %{execute: Steps.Flaky}}
    {:ok, e} = Runtime.explain(Map.put(state, :counterfactual, change))
    assert e.counterfactual.replayed.counterfactual_outcome == :failed
    assert e.counterfactual.replayed.diff.outcome.changed? == false
  end

  test "a refused change is data, and a non-durable run has no replay" do
    {:ok, store} = Ets.start_link()

    {:ok, s} =
      Runtime.run(Steps.workflow(), %{frontier: @frontier},
        providers: [Steps.Flaky, Steps.Local],
        store: store,
        run_id: "ec-2"
      )

    {:ok, e} = Runtime.explain(Map.put(s, :counterfactual, %{outputs: %{nope: 1}}))
    assert %{refused: %{reason: :invalid_change}} = e.counterfactual.replayed

    {:ok, plain} =
      Runtime.run(Steps.workflow(), %{frontier: @frontier}, providers: [Steps.Flaky, Steps.Local])

    assert {:error, %{reason: :not_a_durable_run}} =
             Explain.counterfactual(plain, %{outputs: %{}})
  end
end

defmodule AshPPlan.Reactor.Durable.D4FailedSettleStoreSurvivalTest do
  @moduledoc """
  D4 regression (lane Y4, V10 DIVERGES): a failing plan attempt must leave the store alive.

  Witnessed failure: a beam of `Store.Ets` compiled by a mismatched Elixir crashed the
  GenServer with UndefinedFunctionError (`Enum.__in__/2`) inside the guarded `transition`
  on a failing settle, and every later `release_claim` then got `:noproc`. The guarded
  `:failed` transition (`from: [:pending, :waiting, :polling, :unwinding]`) is the exact
  call shape that hit the bad expansion, so this court replays it on the real store.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.Engine
  alias AshPPlan.Reactor.Durable.Store.Ets

  test "failing plan attempt returns typed {:failed, error} and the store survives it" do
    {:ok, m} =
      AshPPlan.Workflow.Model.new(
        name: "rel",
        goal: "g",
        tasks: [[id: :t, capability: "Observation.Telemetry", authority: :observe]]
      )

    {:ok, store} = Ets.start_link()
    {:ok, run} = Engine.start(store, %{id: "d4", model: m, bindings: %{}, inputs: %{}, context: %{}, parent: nil})

    # Failing settle through the guarded from-list transition path.
    assert {:failed, %{reason: :unbound_tasks, tasks: [:t]}} = Engine.attempt(store, run.id)

    # The store GenServer must still be serving calls (no :noproc crash cascade).
    assert Process.alive?(store)
    assert :ok = Ets.release_claim(store, run.id, self())
    assert %{status: :failed} = Ets.get_run(store, run.id)
  end
end

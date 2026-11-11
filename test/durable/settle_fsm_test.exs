defmodule AshPPlan.Reactor.Durable.SettleFsmTest do
  @moduledoc """
  Court (P14 settle FSM, premises as-landed): the CURRENT FSM table has NO
  `unwinding -> completed` exit (ontology rows are `st:tr_unwinding_to_failed` and
  `st:tr_unwinding_to_unwind_blocked` only), so a completion landing on a mid-run
  `:unwinding` record is LOUDLY refused — logged and returned as
  `{:failed, {:illegal_transition, detail}}` — while a `{:halted, _}` outcome landing
  on a rolling-back record routes to the rollback instead of parking it
  (Engine.settle/4 unwinding/cancelling clauses).

  Anti-vacuity: adding `st:tr_unwinding_to_completed` to ontology.ttl and regenerating
  `Status` flips the `Status.can?/2` assertion and the mid-run completion test.
  """
  use ExUnit.Case, async: false

  Code.require_file("lane_b_fixture.exs", __DIR__)

  alias AshPPlan.Durable.LaneBFx
  alias AshPPlan.Reactor.Durable.{Clock, Engine, Status, Store.Ets, Testing}

  setup do
    LaneBFx.install_adapter!()
    Clock.use_test_clock()
    on_exit(&Clock.reset/0)
    name = :"fx_#{System.unique_integer([:positive])}"
    {:ok, _} = AshPPlan.Test.Effects.start_link(name: name)
    {:ok, store} = Ets.start_link()
    {:ok, store: store, fx: name}
  end

  defp start(store, id, fx, opts \\ []) do
    {:ok, _rec} = Engine.start(store, LaneBFx.attrs(id, fx, opts))
    :ok
  end

  defp wait_until(fun, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(10)
        wait_until(fun, deadline)

      true ->
        flunk("condition never held within budget")
    end
  end

  test "unwinding exits are failed and unwind_blocked only (no completed exit)" do
    assert Status.can?(:unwinding, :failed) == true
    assert Status.can?(:unwinding, :unwind_blocked) == true
    assert Status.can?(:unwinding, :completed) == false
    assert Status.can?(:unwinding, :cancelled) == false
  end

  test "a completion landing on a mid-run :unwinding record is refused (illegal transition)", %{
    store: s,
    fx: fx
  } do
    # `verify` sleeps: while it runs, a concurrent rollback transition lands on the record
    # (:unwinding has no :completed exit in the FSM); the finishing attempt must refuse
    start(s, "h1", fx, extra: %{verify: [sleep: 200]})
    attempt = Task.async(fn -> Engine.attempt(s, "h1") end)
    wait_until(fn -> AshPPlan.Test.Effects.count(fx, :integrate) == 1 end)

    {:ok, _} = Ets.transition(s, "h1", :any, :unwinding, %{error: :mid_run})

    assert {:failed, {:illegal_transition, %{from: :unwinding, to: :completed}}} =
             Task.await(attempt)

    assert Testing.status(s, "h1") == :unwinding
  end

  test "a failure landing on :unwinding settles to :failed (unwinding -> failed)", %{
    store: s,
    fx: fx
  } do
    start(s, "h2", fx, kinds: %{verify: :undo})
    AshPPlan.Test.Effects.fail_after(fx, :verify, 0)

    assert {:failed, _} = Engine.attempt(s, "h2") |> normalise()
    assert Testing.status(s, "h2") == :failed
  end

  test "a run found :unwinding with nothing standing rolls back to :failed", %{store: s, fx: fx} do
    start(s, "h3", fx)
    {:ok, _} = Ets.transition(s, "h3", :any, :unwinding, %{error: :forced})

    assert normalise(Engine.attempt(s, "h3")) == {:failed, :rolled_back}
    assert Testing.status(s, "h3") == :failed
  end

  defp normalise({:rolled_back, :failed}), do: {:failed, :rolled_back}
  defp normalise(other), do: other
end

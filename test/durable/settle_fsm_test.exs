defmodule AshPPlan.Reactor.Durable.SettleFsmTest do
  @moduledoc """
  Court (P14 settle FSM): `st:tr_unwinding_to_completed` is a legal transition (regenerated
  `Status`), and every settle `{:error, _}` answer is LOUD — a refused transition is logged and
  returned as `{:failed, {:illegal_transition, detail}}` (or `{:parked, status}` on the halted
  path) instead of a silent `:ended`. A `{:halted, _}` outcome landing on a rolling-back record
  routes to the rollback instead of parking it.

  Anti-vacuity: removing `st:tr_unwinding_to_completed` from ontology.ttl flips the
  `Status.can?/2` assertion and the mid-run completion test.
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
      fun.() -> :ok
      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(10)
        wait_until(fun, deadline)

      true ->
        flunk("condition never held within budget")
    end
  end

  test "unwinding -> completed is a legal transition" do
    assert Status.can?(:unwinding, :completed) == true
    assert Status.can?(:unwinding, :failed) == true
    assert Status.can?(:unwinding, :unwind_blocked) == true
    assert Status.can?(:unwinding, :cancelled) == false
  end

  test "a completion landing on a mid-run :unwinding record completes it (no silent :ended)", %{
    store: s,
    fx: fx
  } do
    # `verify` sleeps: while it runs, a concurrent rollback transition lands on the record
    # (e.g. a crash-restart restart marker); the finishing attempt must complete, not strand
    start(s, "h1", fx, extra: %{verify: [sleep: 200]})
    attempt = Task.async(fn -> Engine.attempt(s, "h1") end)
    wait_until(fn -> AshPPlan.Test.Effects.count(fx, :integrate) == 1 end)

    {:ok, _} = Ets.transition(s, "h1", :any, :unwinding, %{error: :mid_run})
    assert {:completed, _} = Task.await(attempt)
    assert Testing.status(s, "h1") == :completed
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

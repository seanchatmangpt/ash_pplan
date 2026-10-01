defmodule AshPPlan.Workflow.DurableAdapterTest do
  @moduledoc """
  Court for `AshPPlan.Reactor.Adapters.Durable` and its ontology wiring: every operation resolves
  to a loadable durable `Reactor.Step` with data-only options, the adapter is registered in
  `AshPPlan.Reactor.adapters/0`, the generated providers (`event_state`, `scheduling`,
  `durable_dispatch`) realize their durable capabilities through adapter `:durable`, and the
  default `until` functions answer from arguments and the injectable clock.

  Anti-vacuity: an unknown op is a typed unsupported, a forged realization is refused, and the
  clock-reached predicate flips only when the test clock crosses the instant (mutating
  `clock_reached/3` to always answer `{:ok, _}` fails the not-yet assertion).
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Adapters.Durable
  alias AshPPlan.Reactor.Durable.Clock
  alias AshPPlan.Reactor.Durable.Steps
  alias AshPPlan.Realization

  @ops %{
    human_approve: Steps.Await,
    event_await: Steps.Await,
    state_await: Steps.Poll,
    schedule_deferred: Steps.Poll,
    scheduling_deferred: Steps.Poll,
    workflow_dispatch: Steps.Dispatch
  }

  test "adapter is registered and always available" do
    assert AshPPlan.Reactor.adapters()[:durable] == Durable
    assert Durable.id() == :durable
    assert Durable.available?()
    assert Enum.sort(Durable.ops()) == Enum.sort(Map.keys(@ops))
  end

  test "every op resolves to its durable step with data-only options" do
    for {op, mod} <- @ops do
      assert {:ok, {^mod, opts}} = Durable.step(op, [])
      assert Code.ensure_loaded?(mod)
      assert :ok = AshPPlan.Reactor.validate_step(mod)
      assert Keyword.keyword?(opts)

      for {_k, v} <- opts do
        refute is_function(v), "#{op} carries a closure option"
        refute is_pid(v)
      end
    end
  end

  test "options passed by the realization override the defaults" do
    assert {:ok, {Steps.Await, opts}} = Durable.step(:event_await, signal: "go", timeout: 5)
    assert opts[:signal] == "go"
    assert opts[:timeout] == 5
  end

  test "anti-vacuity: an unknown op is a typed unsupported" do
    assert {:error, %{reason: :unsupported, adapter: :durable, detail: {:unknown_op, :nope}}} =
             Durable.step(:nope, [])

    forged = %Realization{
      capability: "Event.Await",
      provider: :x,
      binding: %{adapter: :durable, op: :nope}
    }

    assert {:error, %{reason: :unsupported}} = AshPPlan.Reactor.step_for(forged)
  end

  test "a realization binds through AshPPlan.Reactor.step_for/1" do
    r = %Realization{
      capability: "Workflow.Dispatch",
      provider: :durable_dispatch,
      binding: %{adapter: :durable, op: :workflow_dispatch}
    }

    assert {:ok, {Steps.Dispatch, _}} = AshPPlan.Reactor.step_for(r)
  end

  describe "generated providers realize through :durable" do
    @expected [
      {AshPPlan.Generated.Providers.EventState, "Event.Await", :event_await, Steps.Await},
      {AshPPlan.Generated.Providers.EventState, "State.Await", :state_await, Steps.Poll},
      {AshPPlan.Generated.Providers.Scheduling, "Scheduling.Deferred", :scheduling_deferred,
       Steps.Poll},
      {AshPPlan.Generated.Providers.DurableDispatch, "Workflow.Dispatch", :workflow_dispatch,
       Steps.Dispatch}
    ]

    test "adapter, op and step" do
      for {provider, cap, op, step} <- @expected do
        assert cap in provider.capabilities()
        assert {:ok, %Realization{} = r} = provider.realize(%{capability: cap}, %{})
        assert r.binding == %{adapter: :durable, op: op}
        assert {:ok, {^step, _}} = AshPPlan.Reactor.step_for(r)
      end
    end

    test "State.Observe stays local (it never parks)" do
      provider = AshPPlan.Generated.Providers.EventState
      assert {:ok, r} = provider.realize(%{capability: "State.Observe"}, %{})
      assert r.binding.adapter == :local
    end
  end

  describe "default option functions" do
    setup do
      Clock.use_test_clock(~U[2026-01-01 00:00:00Z])
      on_exit(&Clock.reset/0)
    end

    test "clock_reached/3 flips when the test clock crosses the instant" do
      at = ~U[2026-01-01 00:00:10Z]
      assert Durable.clock_reached(%{not_before: at}, %{}, :not_before) == :not_yet
      Clock.advance(9_999)
      assert Durable.clock_reached(%{not_before: at}, %{}, :not_before) == :not_yet
      Clock.advance(1)
      assert {:ok, _} = Durable.clock_reached(%{not_before: at}, %{}, :not_before)
    end

    test "clock_reached/3 with no instant is due now" do
      assert {:ok, _} = Durable.clock_reached(%{}, %{}, :not_before)
    end

    test "argument_until/3 answers from the argument" do
      assert Durable.argument_until(%{}, %{}, :ready) == :not_yet
      assert Durable.argument_until(%{ready: false}, %{}, :ready) == :not_yet
      assert Durable.argument_until(%{ready: :yes}, %{}, :ready) == {:ok, :yes}
    end

    test "step_signal/2 is the running step's label" do
      ctx = %{current_step: %{name: "urn:x#step-a"}}
      assert Durable.step_signal(%{}, ctx) == AshPPlan.Reactor.Durable.Key.label("urn:x#step-a")
    end
  end
end

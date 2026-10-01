defmodule AshPPlan.Reactor.Durable.TestingTest do
  @moduledoc """
  Court for `AshPPlan.Reactor.Durable.Testing` and `AshPPlan.Test.Effects`: the helpers must drive
  a real engine over a real ETS store. Anti-vacuity: a drain with nothing runnable is a no-op, a
  tape of an unfinished run is a strict prefix of the finished one, and an `Effects` counter armed
  with `fail_after` really refuses the next execution.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.{Clock, Engine, Testing}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Test.{DurableFx, Effects}

  setup do
    DurableFx.install_adapter!()
    Clock.use_test_clock()
    on_exit(&Clock.reset/0)
    {:ok, store} = Ets.start_link()
    {:ok, _} = Effects.start_link()
    {:ok, store: store}
  end

  describe "Effects" do
    test "counts per effect and reports all" do
      assert Effects.record(:a) == 1
      assert Effects.record(:a) == 2
      assert Effects.record(:b) == 1
      assert Effects.count(:a) == 2
      assert Effects.count(:never) == 0
      assert Effects.all() == %{a: 2, b: 1}
    end

    test "fail_after refuses the next execution and leaves the count" do
      Effects.fail_after(:pay, 1)
      assert {:ok, 1} = Effects.run(:pay)
      assert {:error, {:effect_failed, :pay}} = Effects.run(:pay)
      assert Effects.count(:pay) == 1
    end
  end

  describe "drain / tape / status / recorded" do
    test "drain on an empty store is a no-op", %{store: store} do
      assert Testing.drain(store) == []
    end

    test "drain parks at the human release, then a signal completes it", %{store: store} do
      {:ok, _} = Engine.start(store, DurableFx.attrs("t-1"))

      assert [{"t-1", {:parked, _}}] = Testing.drain(store)
      assert Testing.status(store, "t-1") in [:waiting, :polling]
      assert Testing.waiting_on(store, "t-1") == [DurableFx.signal_name()]
      partial = Testing.tape(store, "t-1")
      assert Effects.all() == %{admit: 1, authorize: 1}

      {:ok, _} = Testing.signal(store, "t-1", DurableFx.signal_name(), :approved)
      assert [{"t-1", {:completed, _}}] = Testing.drain(store)
      assert Testing.status(store, "t-1") == :completed

      full = Testing.tape(store, "t-1")
      assert length(full) == 4
      assert Enum.take(full, length(partial)) == partial
      assert length(partial) < length(full)
      assert Effects.all() == %{admit: 1, authorize: 1, commit: 1}
      assert Testing.recorded(store, "t-1", :nonexistent_step) == nil
    end

    test "status of an unknown run is nil", %{store: store} do
      assert Testing.status(store, "nope") == nil
    end
  end
end

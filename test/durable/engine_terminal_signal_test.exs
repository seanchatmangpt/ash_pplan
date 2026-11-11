defmodule AshPPlan.Reactor.Durable.EngineTerminalSignalTest do
  use ExUnit.Case, async: true

  alias AshPPlan.Reactor.Durable.{Engine, Store.Ets}

  test "signal to a terminal run is refused as {:run_terminal, status}, not an orphan" do
    {:ok, store} = Ets.start_link()
    {:ok, _} = Engine.start(store, %{id: "r-term", model: :m})

    {:ok, _} =
      Ets.transition(store, "r-term", :any, :completed, %{result: 42})

    assert {:error, {:run_terminal, :completed}} =
             Engine.signal(store, "r-term", "go", :p)

    assert {:error, :no_such_run} = Engine.signal(store, "nope", "go", :p)
  end

  test "cancelling and unwinding runs still accept signals" do
    {:ok, store} = Ets.start_link()
    {:ok, _} = Engine.start(store, %{id: "r-cx", model: :m})
    {:ok, _} = Ets.transition(store, "r-cx", :any, :cancelling, %{})

    assert {:ok, _} = Engine.signal(store, "r-cx", "go", :p)
  end
end

defmodule AshPPlan.Reactor.Durable.PollTest do
  @moduledoc """
  Court for `Durable.Steps.Poll`: satisfied returns the value and releases its waiter;
  `:not_yet` parks a poll waiter and halts structurally; every is clamped to >= 1 ms; a stale
  poll waiter is released on success. Real `Store.Ets`, hand-built `context.durable`.
  Anti-vacuity: the condition is read from a real Agent, so flipping it flips the outcome.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.Clock
  alias AshPPlan.Reactor.Durable.Steps.Poll
  alias AshPPlan.Reactor.Durable.Store.Ets

  setup do
    Clock.use_test_clock(~U[2026-01-01 00:00:00Z])
    on_exit(&Clock.reset/0)
    {:ok, store} = Ets.start_link([])

    {:ok, _} =
      Ets.start_run(store, %{id: "r1", model: nil, bindings: %{}, inputs: %{}, context: %{}})

    {:ok, flag} = Agent.start_link(fn -> false end)
    %{store: store, flag: flag}
  end

  def check(%{flag: flag}, _ctx), do: if(Agent.get(flag, & &1), do: {:ok, :done}, else: :not_yet)

  defp ctx(store),
    do: %{
      durable: %{store: store, run_id: "r1", checkpoints: %{}},
      durable_step: %{name: :p},
      current_step: %{name: :p}
    }

  test "not_yet parks a poll waiter and halts; satisfied returns and releases", %{
    store: store,
    flag: flag
  } do
    opts = [until: {__MODULE__, :check, []}, every: 250]

    assert {:halt, %{awaiting: ":p", kind: :poll, deadline: dl}} =
             Poll.run(%{flag: flag}, ctx(store), opts)

    assert DateTime.compare(dl, ~U[2026-01-01 00:00:00.250Z]) == :eq
    assert %{kind: :poll} = Ets.get_waiter(store, "r1", ":p")

    Agent.update(flag, fn _ -> true end)
    assert {:ok, :done} = Poll.run(%{flag: flag}, ctx(store), opts)
    assert Ets.get_waiter(store, "r1", ":p") == nil
    assert Ets.waiters(store, "r1") == []
  end

  test "every is clamped to at least 1ms", %{store: store, flag: flag} do
    assert {:halt, %{deadline: dl}} =
             Poll.run(%{flag: flag}, ctx(store), until: {__MODULE__, :check, []}, every: 0)

    assert DateTime.compare(dl, ~U[2026-01-01 00:00:00.001Z]) == :eq
  end

  test "re-poll refreshes the waiter deadline", %{store: store, flag: flag} do
    opts = [until: {__MODULE__, :check, []}, every: 100]
    {:halt, _} = Poll.run(%{flag: flag}, ctx(store), opts)
    Clock.advance(100)
    {:halt, %{deadline: d2}} = Poll.run(%{flag: flag}, ctx(store), opts)
    assert Ets.get_waiter(store, "r1", ":p").deadline == d2
  end

  test "outside a durable plan refuses", %{store: store, flag: flag} do
    assert_raise ArgumentError, fn ->
      Poll.run(%{flag: flag}, %{durable: %{store: store, run_id: "r1"}},
        until: {__MODULE__, :check, []}
      )
    end
  end
end

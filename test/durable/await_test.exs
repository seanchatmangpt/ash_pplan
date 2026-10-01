defmodule AshPPlan.Reactor.Durable.AwaitTest do
  @moduledoc """
  Court for `Durable.Steps.Await`: parks with a waiter and no spin, takes an early signal,
  delivers the payload, answers timeouts as error or tagged value, and never moves a deadline.
  Real `Store.Ets` collaborator, hand-built `context.durable` (engine-level courts live in the
  Engine suites). Anti-vacuity mutation (run manually): replacing the waiter read-back in `Await.park/7` with a fresh
  deadline makes the deadline court fail.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.{Clock, TimeoutError}
  alias AshPPlan.Reactor.Durable.Steps.Await
  alias AshPPlan.Reactor.Durable.Store.Ets

  setup do
    Clock.use_test_clock(~U[2026-01-01 00:00:00Z])
    on_exit(&Clock.reset/0)
    {:ok, store} = Ets.start_link([])

    {:ok, _} =
      Ets.start_run(store, %{id: "r1", model: nil, bindings: %{}, inputs: %{}, context: %{}})

    %{store: store}
  end

  defp ctx(store, name \\ :w),
    do: %{
      durable: %{store: store, run_id: "r1", checkpoints: %{}},
      durable_step: %{name: name},
      current_step: %{name: name}
    }

  test "no durable_step context refuses loudly", %{store: store} do
    assert_raise ArgumentError, fn ->
      Await.run(%{}, %{durable: %{store: store, run_id: "r1"}}, signal: "go")
    end
  end

  test "parks with a waiter and halts with structure", %{store: store} do
    assert {:halt, %{awaiting: "go", kind: :signal, deadline: nil}} =
             Await.run(%{}, ctx(store), signal: "go")

    assert %{kind: :signal, name: "go"} = Ets.get_waiter(store, "r1", "go")
  end

  test "early signal is taken, payload returned, waiter gone", %{store: store} do
    {:ok, _} = Ets.deliver_signal(store, "r1", "go", %{n: 1})
    assert {:ok, %{n: 1}} = Await.run(%{}, ctx(store), signal: "go")
    assert Ets.get_waiter(store, "r1", "go") == nil
    # consume-once: second await parks
    assert {:halt, _} = Await.run(%{}, ctx(store), signal: "go")
  end

  test "signal delivered after parking is taken on the next attempt", %{store: store} do
    assert {:halt, _} = Await.run(%{}, ctx(store), signal: "go")
    {:ok, _} = Ets.deliver_signal(store, "r1", "go", :hi)
    assert {:ok, :hi} = Await.run(%{}, ctx(store), signal: "go")
    assert Ets.get_waiter(store, "r1", "go") == nil
  end

  test "MFA signal name", %{store: store} do
    {:ok, _} = Ets.deliver_signal(store, "r1", "n-7", 1)
    assert {:ok, 1} = Await.run(%{id: 7}, ctx(store), signal: {__MODULE__, :name, []})
  end

  def name(%{id: id}, _ctx), do: "n-#{id}"
  def ms(_a, _c), do: 500

  test "independent waits park together", %{store: store} do
    assert {:halt, _} = Await.run(%{}, ctx(store, :a), signal: "a")
    assert {:halt, _} = Await.run(%{}, ctx(store, :b), signal: "b")
    assert ["a", "b"] = store |> Ets.waiters("r1") |> Enum.map(& &1.name) |> Enum.sort()
    {:ok, _} = Ets.deliver_signal(store, "r1", "b", :B)
    {:ok, _} = Ets.deliver_signal(store, "r1", "a", :A)
    assert {:ok, :B} = Await.run(%{}, ctx(store, :b), signal: "b")
    assert {:ok, :A} = Await.run(%{}, ctx(store, :a), signal: "a")
  end

  test "timeout: error", %{store: store} do
    assert {:halt, %{deadline: dl}} = Await.run(%{}, ctx(store), signal: "go", timeout: 1000)
    assert DateTime.compare(dl, ~U[2026-01-01 00:00:01.000Z]) == :eq
    Clock.advance(1000)

    assert {:error, %TimeoutError{signal: "go"}} =
             Await.run(%{}, ctx(store), signal: "go", timeout: 1000)
  end

  test "timeout: tagged return, MFA timeout", %{store: store} do
    opts = [signal: "go", timeout: {__MODULE__, :ms, []}, on_timeout: :return]
    assert {:halt, %{deadline: dl}} = Await.run(%{}, ctx(store), opts)
    assert DateTime.compare(dl, ~U[2026-01-01 00:00:00.500Z]) == :eq
    Clock.advance(500)
    assert {:ok, {:timeout, "go"}} = Await.run(%{}, ctx(store), opts)
  end

  test "deadline cannot move once parked", %{store: store} do
    assert {:halt, %{deadline: d1}} = Await.run(%{}, ctx(store), signal: "go", timeout: 1000)
    Clock.advance(400)
    assert {:halt, %{deadline: d2}} = Await.run(%{}, ctx(store), signal: "go", timeout: 99_999)
    assert d1 == d2
  end

  test "block_ms returns a signal that lands in the window", %{store: store} do
    task = Task.async(fn -> Await.run(%{}, ctx(store), signal: "go", block_ms: 2000) end)
    Process.sleep(50)
    {:ok, _} = Ets.deliver_signal(store, "r1", "go", :late)
    assert {:ok, :late} = Task.await(task, 5000)
  end
end

defmodule AshPPlan.Reactor.Durable.LeaseMonitorTest do
  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.LeaseMonitor

  setup do
    name = :"lease_monitor_#{System.unique_integer([:positive])}"
    start_supervised!({LeaseMonitor, name: name})
    %{monitor: name}
  end

  test "claiming and heartbeating monotonic epochs", %{monitor: monitor} do
    run_id = "run-#{System.unique_integer([:positive])}"
    worker = self()

    assert {:ok, 1} = LeaseMonitor.claim(monitor, run_id, worker)
    assert {:held, ^worker, 1} = LeaseMonitor.status(monitor, run_id)

    assert {:ok, 2} = LeaseMonitor.heartbeat(monitor, run_id, worker)
    assert {:held, ^worker, 2} = LeaseMonitor.status(monitor, run_id)

    LeaseMonitor.release(monitor, run_id, worker)
    assert :vacant = LeaseMonitor.status(monitor, run_id)
  end

  test "worker crash immediately releases lease via process monitor without 30s delay", %{
    monitor: monitor
  } do
    run_id = "run-crash-#{System.unique_integer([:positive])}"

    worker =
      spawn(fn ->
        receive do
          :die -> exit(:crash)
        end
      end)

    assert {:ok, 1} = LeaseMonitor.claim(monitor, run_id, worker)
    assert {:held, ^worker, 1} = LeaseMonitor.status(monitor, run_id)

    # Crash the worker
    send(worker, :die)
    :timer.sleep(20)

    # Lease is immediately vacant!
    assert :vacant = LeaseMonitor.status(monitor, run_id)
  end
end

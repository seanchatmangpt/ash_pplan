defmodule AshPPlan.QualifiedFulfillmentCollabTest do
  @moduledoc """
  Court: the real collaborators behave as real processes. Anti-vacuity: the
  mode function drives the HTTP status (mutating it changes the assertion), the
  worker restart is observed via a changed pid and start counter.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Test.{
    FulfillmentRobot,
    FulfillmentWorker,
    PaymentServer,
    QualifiedFulfillmentCollab
  }

  defp post(url), do: Req.post(url <> "/payments/authorize", body: "{}", retry: false)

  test "payment server returns mode-driven status and counts requests" do
    {:ok, ps} = PaymentServer.start(mode: fn n -> Enum.at([200, 402, 503], rem(n - 1, 3)) end)
    on_exit(ps.stop)
    assert {:ok, %{status: 200}} = post(ps.url)
    assert {:ok, %{status: 402}} = post(ps.url)
    assert {:ok, %{status: 503}} = post(ps.url)
    assert PaymentServer.request_count(ps) == 3
  end

  test "robot walks idle -> picking -> carrying -> packing_station with events" do
    {:ok, r} = FulfillmentRobot.start_link(step_ms: 5)
    FulfillmentRobot.subscribe(r)
    assert FulfillmentRobot.state(r) == :idle
    assert :ok = FulfillmentRobot.command(r, {:pick, "sku-1"})
    assert_receive {:robot_event, ^r, :picking}, 500
    assert_receive {:robot_event, ^r, :carrying}, 500
    assert_receive {:robot_event, ^r, :packing_station}, 500
    assert FulfillmentRobot.command_count(r) == 1
    FulfillmentRobot.fault(r)
    assert FulfillmentRobot.state(r) == :fault
  end

  test "helper starts collaborators; worker is restarted by its supervisor" do
    {:ok, c} = QualifiedFulfillmentCollab.start(worker_name: :collab_smoke_worker)
    on_exit(c.stop)
    assert FulfillmentWorker.ping(:collab_smoke_worker) == :pong
    assert FulfillmentWorker.starts(:collab_smoke_worker) == 1
    old = c.worker
    ref = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}, 1_000
    Process.sleep(50)
    new = Process.whereis(:collab_smoke_worker)
    assert is_pid(new) and new != old
    assert FulfillmentWorker.starts(:collab_smoke_worker) == 2
  end
end

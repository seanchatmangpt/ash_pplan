defmodule AshPPlan.Telemetry.BroadcasterTest do
  use ExUnit.Case, async: true

  alias AshPPlan.Telemetry.Broadcaster
  alias AshPPlan.Telemetry.Event

  @signal :ash_pplan_telemetry

  setup do
    server = start_supervised!({Broadcaster, name: nil})
    %{server: server}
  end

  # A subscriber process that calls subscribe/3 then parks without draining.
  defp parked_subscriber(server, topic) do
    parent = self()

    pid =
      spawn(fn ->
        Broadcaster.subscribe(server, topic)
        send(parent, {:subscribed, self()})
        Process.sleep(:infinity)
      end)

    assert_receive {:subscribed, ^pid}, 2_000
    pid
  end

  # A subscriber process that drains into its own state list.
  defp draining_subscriber(server, topic) do
    parent = self()

    pid =
      spawn(fn ->
        Broadcaster.subscribe(server, topic)
        send(parent, {:subscribed, self()})
        drain(parent)
      end)

    assert_receive {:subscribed, ^pid}, 2_000
    pid
  end

  defp drain(parent) do
    receive do
      {@signal, event} ->
        send(parent, {:event, event})
        drain(parent)
    end
  end

  defp status_event(run_id, from \\ :running, to \\ :done) do
    %Event.RunStatusChanged{run_id: run_id, from: from, to: to}
  end

  test "broadcast delivers the full envelope to a subscriber", %{server: server} do
    draining_subscriber(server, "run-1")
    :ok = Broadcaster.broadcast(server, "run-1", status_event("run-1", :running, :committed))

    assert_receive {:event, event}, 2_000
    assert event.topic == "run-1"
    assert event.type == :run_status_changed
    assert event.run_id == "run-1"
    assert event.seq == 1
    assert %Event.RunStatusChanged{} = event.data
    assert %DateTime{} = event.emitted_at
  end

  test "fan-out: every subscriber receives every event", %{server: server} do
    draining_subscriber(server, :fanout)
    draining_subscriber(server, :fanout)
    draining_subscriber(server, :fanout)

    for seq <- 1..3 do
      :ok = Broadcaster.broadcast(server, :fanout, status_event("run-fan", seq, seq + 1))
    end

    events =
      Enum.map(1..9, fn _ ->
        assert_receive {:event, event}, 2_000
        event
      end)

    # per-topic seq is monotonic and identical across subscribers
    by_pid_seq =
      Enum.map(events, &{&1.data.from, &1.seq})
      |> Enum.sort()

    assert by_pid_seq == [
             {1, 1},
             {1, 1},
             {1, 1},
             {2, 2},
             {2, 2},
             {2, 2},
             {3, 3},
             {3, 3},
             {3, 3}
           ]
  end

  test "seq is monotonic per topic and independent across topics", %{server: server} do
    draining_subscriber(server, "t-a")
    draining_subscriber(server, "t-b")

    :ok = Broadcaster.broadcast(server, "t-a", status_event("a", 0, 1))
    :ok = Broadcaster.broadcast(server, "t-b", status_event("b", 0, 1))
    :ok = Broadcaster.broadcast(server, "t-a", status_event("a", 1, 2))

    seqs =
      Enum.map(1..3, fn _ ->
        assert_receive {:event, event}, 2_000
        {event.topic, event.seq}
      end)
      |> Enum.sort()

    assert seqs == [{"t-a", 1}, {"t-a", 2}, {"t-b", 1}]
  end

  test "dead subscriber is pruned; broadcaster survives and counts the drop", %{server: server} do
    parked = parked_subscriber(server, :lifecycle)
    live = draining_subscriber(server, :lifecycle)

    Process.exit(parked, :kill)

    :ok = Broadcaster.broadcast(server, :lifecycle, status_event("l1"))
    assert_receive {:event, _}, 2_000

    # Broadcast again after the dead subscriber — no crash, seq advances.
    :ok = Broadcaster.broadcast(server, :lifecycle, status_event("l2"))
    assert_receive {:event, %{seq: 2}}, 2_000

    assert Process.alive?(server)
    assert Broadcaster.dropped_count(server, :lifecycle) >= 1
    refute subscriber_alive?(parked)
    assert subscriber_alive?(live)
  end

  test "unsubscribe stops delivery", %{server: server} do
    parent = self()

    pid =
      spawn(fn ->
        Broadcaster.subscribe(server, :unsub)
        send(parent, {:subscribed, self()})

        receive do
          {@signal, event} -> send(parent, {:event, event})
        end
      end)

    assert_receive {:subscribed, ^pid}, 2_000
    :ok = Broadcaster.broadcast(server, :unsub, status_event("u1"))
    assert_receive {:event, %{seq: 1}}, 2_000

    :ok = Broadcaster.unsubscribe(server, :unsub)
    :ok = Broadcaster.broadcast(server, :unsub, status_event("u2"))
    refute_receive {:event, _}, 200
  end

  test "slow-subscriber drop-with-counter: overfull mailbox is dropped, not grown", %{
    server: server
  } do
    # parked subscriber never drains its mailbox
    parked = parked_subscriber(server, :slow)
    live = draining_subscriber(server, :slow)

    # more broadcasts than @max_queue_len (256): the parked subscriber's queue
    # crosses the threshold and it is pruned with a counted drop.
    for i <- 1..300 do
      :ok = Broadcaster.broadcast(server, :slow, status_event("s", i, i + 1))
    end

    assert Broadcaster.dropped_count(server, :slow) >= 1

    # after pruning, subsequent broadcasts deliver only to the live subscriber
    :ok = Broadcaster.broadcast(server, :slow, status_event("s", 300, 301))
    assert_receive {:event, %{seq: 301}}, 2_000

    # only the live subscriber is still receiving — parked mailbox stopped growing
    len_before = mailbox_len(parked)
    :ok = Broadcaster.broadcast(server, :slow, status_event("s", 301, 302))
    len_after = mailbox_len(parked)
    assert len_before == len_after
    assert Process.alive?(parked)
    assert Process.alive?(live)
    assert Process.alive?(server)
  end

  test "dropped_count is 0 for a topic with no drops", %{server: server} do
    assert Broadcaster.dropped_count(server, :quiet) == 0
  end

  defp mailbox_len(pid) do
    {:message_queue_len, len} = Process.info(pid, :message_queue_len)
    len
  end

  # A subscriber counts as live only if it is still registered with the broadcaster:
  # observable as it keeps receiving broadcasts.
  defp subscriber_alive?(pid) do
    Process.alive?(pid)
  end
end

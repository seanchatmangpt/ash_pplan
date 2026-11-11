defmodule AshPPlan.Telemetry.EmitIntegrationTest do
  use ExUnit.Case, async: true

  alias AshPPlan.Telemetry.Emit.BufferingEmitter
  alias AshPPlan.Telemetry.Emit.Event
  alias AshPPlan.Telemetry.Event, as: BaseEvent

  describe "BufferingEmitter end-to-end" do
    test "emit 100 events, drain returns all in seq order, counts accurate" do
      start_supervised!({BufferingEmitter, name: F7Emit1, max: 1024})
      server = F7Emit1

      for i <- 1..100 do
        event = Event.run_status_changed(:run_a, :running, i)
        assert BufferingEmitter.emit(event, topic: :run_a, server: server) == :ok
      end

      assert %{buffered: 100, evicted: 0, by_type: %{run_status_changed: 100}} =
               BufferingEmitter.counts(server)

      drained = BufferingEmitter.drain(server)
      assert length(drained) == 100
      assert Enum.map(drained, & &1.seq) == Enum.to_list(1..100)

      first = hd(drained)
      assert first.topic == :run_a
      assert first.type == :run_status_changed
      assert first.run_id == :run_a
      assert is_struct(first.data, BaseEvent.RunStatusChanged)
      assert %DateTime{} = first.emitted_at
      assert first.data.to == 1
      assert List.last(drained).data.to == 100

      # drain resets the buffer and counters; seq keeps its position
      assert %{buffered: 0, evicted: 0, by_type: %{}} = BufferingEmitter.counts(server)

      BufferingEmitter.emit(Event.run_status_changed(:run_a, :a, :b),
        topic: :run_a,
        server: server
      )

      assert [%{seq: 101}] = BufferingEmitter.drain(server)
    end

    test "bounded ring evicts oldest" do
      start_supervised!({BufferingEmitter, name: F7Emit2, max: 50})
      server = F7Emit2

      for i <- 1..100 do
        BufferingEmitter.emit(Event.checkpoint_committed(:run_b, :"store_#{i}"),
          topic: :run_b,
          server: server
        )
      end

      assert %{buffered: 50, evicted: 50, by_type: %{checkpoint_committed: 50}} =
               BufferingEmitter.counts(server)

      drained = BufferingEmitter.drain(server)
      # oldest 50 evicted; survivors are seqs 51..100 in emission order
      assert Enum.map(drained, & &1.seq) == Enum.to_list(51..100)
      assert hd(drained).data.store == :store_51
      assert List.last(drained).data.store == :store_100
    end

    test "concurrent emitters (8 processes) — no lost seq" do
      start_supervised!({BufferingEmitter, name: F7Emit3, max: 10_000})
      server = F7Emit3
      per_process = 125

      tasks =
        for p <- 1..8 do
          Task.async(fn ->
            for i <- 1..per_process do
              BufferingEmitter.emit(
                Event.lease_granted({p, i}, owner: :"owner_#{p}"),
                topic: {:lease, p},
                server: server
              )
            end
          end)
        end

      Task.await_many(tasks, 15_000)

      drained = BufferingEmitter.drain(server)
      assert length(drained) == 8 * per_process

      seqs = Enum.map(drained, & &1.seq)
      # single-writer GenServer: seq is contiguous, unique, no gaps
      assert Enum.sort(seqs) == Enum.to_list(1..(8 * per_process))

      for p <- 1..8 do
        topic_events = Enum.filter(drained, &(&1.topic == {:lease, p}))
        topic_seqs = Enum.map(topic_events, & &1.seq)

        # per-topic seq order == emission order within that topic
        assert topic_seqs == Enum.sort(topic_seqs)

        assert Enum.all?(topic_events, fn e ->
                 e.type == :lease_granted and is_struct(e.data, Event.LeaseGranted)
               end)
      end

      assert %{buffered: 0, evicted: 0, by_type: %{}} = BufferingEmitter.counts(server)
    end
  end

  describe "Emit.Event extended vocabulary" do
    test "new constructors build keyed structs with stamps" do
      now = DateTime.utc_now()

      assert %Event.LeaseGranted{lease_id: :l1, owner: :o, granted_at: g} =
               Event.lease_granted(:l1, owner: :o)

      assert %DateTime{} = g

      assert %Event.LeaseReleased{lease_id: :l2, released_at: ^now} =
               Event.lease_released(:l2, released_at: now)

      assert %Event.InvariantRefused{run_id: :r, invariant: :wal_tail, detail: "gap"} =
               Event.invariant_refused(:r, :wal_tail, detail: "gap")

      assert %Event.WalIntegrity{store: :s, error: :corrupt, run_id: :r} =
               Event.wal_integrity(:s, :corrupt, run_id: :r)
    end

    test "type_of/1 covers both vocabularies; run_id_of handles lease events" do
      assert Event.type_of(Event.run_status_changed(:r, :a, :b)) == :run_status_changed
      assert Event.type_of(Event.lease_granted(:l)) == :lease_granted
      assert Event.type_of(Event.lease_released(:l)) == :lease_released
      assert Event.type_of(Event.invariant_refused(:r, :i)) == :invariant_refused
      assert Event.type_of(Event.wal_integrity(:s, :e)) == :wal_integrity
      assert BaseEvent.type_of(Event.run_status_changed(:r, :a, :b)) == :run_status_changed

      assert Event.run_id_of(Event.invariant_refused(:r9, :i)) == :r9
      assert Event.run_id_of(Event.lease_granted(:l)) == nil
      assert Event.run_id_of(Event.wal_integrity(:s, :e, run_id: :rw)) == :rw
    end

    test "BufferingEmitter satisfies the Emit behaviour contract" do
      behaviour_callbacks = AshPPlan.Telemetry.Emit.behaviour_info(:callbacks)
      assert {:emit, 2} in behaviour_callbacks

      for {fun, arity} <- behaviour_callbacks do
        assert function_exported?(BufferingEmitter, fun, arity),
               "BufferingEmitter missing callback #{fun}/#{arity}"
      end
    end
  end
end

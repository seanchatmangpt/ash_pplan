defmodule AshPPlan.Telemetry.EventTest do
  use ExUnit.Case, async: true

  alias AshPPlan.Telemetry.Event

  test "structs enforce their identity keys" do
    assert_raise(KeyError, fn -> %Event.CheckpointCommitted{} end)
    assert_raise(KeyError, fn -> %Event.RunStatusChanged{} end)
    assert_raise(KeyError, fn -> %Event.HazardTripped{} end)
    assert_raise(KeyError, fn -> %Event.LeaseExpired{} end)
    assert_raise(KeyError, fn -> %Event.ReceiptObserved{} end)
  end

  test "type_of discriminates the vocabulary" do
    assert Event.type_of(%Event.CheckpointCommitted{run_id: :r, store: :ets}) ==
             :checkpoint_committed

    assert Event.type_of(%Event.RunStatusChanged{run_id: :r, from: :a, to: :b}) ==
             :run_status_changed

    assert Event.type_of(%Event.HazardTripped{run_id: :r, hazard: :overdraft}) ==
             :hazard_tripped

    assert Event.type_of(%Event.LeaseExpired{lease_id: :l}) == :lease_expired
    assert Event.type_of(%Event.ReceiptObserved{run_id: :r, receipt_id: :x}) == :receipt_observed
  end

  test "to_event stamps topic, seq, emitted_at and preserves the struct" do
    data = %Event.HazardTripped{run_id: "r9", hazard: :depeg, detail: "0.4"}
    event = Event.to_event(data, "r9", 7)

    assert event.topic == "r9"
    assert event.type == :hazard_tripped
    assert event.run_id == "r9"
    assert event.seq == 7
    assert event.data == data
    assert %DateTime{} = event.emitted_at
  end

  test "run_id_of is nil for events without a run (lease)" do
    assert Event.run_id_of(%Event.LeaseExpired{lease_id: "lease-1"}) == nil
    assert Event.run_id_of(%Event.ReceiptObserved{run_id: "r2", receipt_id: "x"}) == "r2"
  end
end

defmodule AshPPlan.Reactor.Durable.RingBufferTest do
  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.RingBuffer

  setup do
    RingBuffer.init()
    :ok
  end

  test "monotonic sequence allocation and batch reads" do
    run_id = "test-run-#{System.unique_integer([:positive])}"

    {:ok, seq1} = RingBuffer.push(run_id, :step_a, {:val, 1})
    {:ok, seq2} = RingBuffer.push(run_id, :step_b, {:val, 2})

    assert seq2 == seq1 + 1

    entries = RingBuffer.read_batch(seq1, 10)
    assert length(entries) >= 2

    {found_seq1, ^run_id, :step_a, {:val, 1}, _, _} = hd(entries)
    assert found_seq1 == seq1
  end

  test "pruning old acknowledged entries" do
    run_id = "test-run-prune"
    {:ok, s1} = RingBuffer.push(run_id, :s1, 1)
    {:ok, s2} = RingBuffer.push(run_id, :s2, 2)

    RingBuffer.prune(s1)
    assert RingBuffer.read_batch(s1, 1) == []
    assert length(RingBuffer.read_batch(s2, 1)) == 1
  end
end

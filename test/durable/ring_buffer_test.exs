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

  test "concurrent pushes advance monotonic sequence without race conditions" do
    num_processes = 20
    pushes_per_process = 50
    total_pushes = num_processes * pushes_per_process

    tasks =
      for p <- 1..num_processes do
        Task.async(fn ->
          run_id = "conc-run-#{p}"

          for i <- 1..pushes_per_process do
            {:ok, seq} = RingBuffer.push(run_id, :"step_#{i}", {p, i})
            seq
          end
        end)
      end

    all_seqs =
      tasks
      |> Enum.flat_map(&Task.await(&1, 5000))
      |> Enum.sort()

    # All returned sequences must be unique (no collision)
    assert length(all_seqs) == total_pushes
    assert length(Enum.uniq(all_seqs)) == total_pushes

    # Every sequence is strictly monotonic (each consecutive difference is exactly 1)
    [head | tail] = all_seqs

    tail
    |> Enum.reduce(head, fn seq, prev ->
      assert seq == prev + 1
      seq
    end)
  end

  test "capacity bound evicts oldest entries on push (wrap/evict)" do
    Application.put_env(:ash_pplan, :ring_buffer_capacity, 8)
    try do
      AshPPlan.Reactor.Durable.RingBuffer.init()

      for _ <- 1..20, do: AshPPlan.Reactor.Durable.RingBuffer.push("r1", :step, :out, %{})
      # eviction is amortized (every 512th push); force the sweep for the assertion
      AshPPlan.Reactor.Durable.RingBuffer.evict_now()
      head = AshPPlan.Reactor.Durable.RingBuffer.head_seq()

      rows =
        :ets.tab2list(:ash_pplan_ring_buffer)
        |> Enum.filter(fn
          {k, _, _} when k == :__seq_meta__ -> false
          {_, _, _, _, _, _} -> true
          _ -> false
        end)

      assert length(rows) == 8
      # oldest window kept, newest present
      assert AshPPlan.Reactor.Durable.RingBuffer.read_batch(head - 7, 100) |> length() == 8
      # evicted seqs 1..12 are skipped (gap-fill), only the retained window is returned
      assert Enum.all?(AshPPlan.Reactor.Durable.RingBuffer.read_batch(1, 100), &elem(&1, 0) >= 13)
    after
      Application.delete_env(:ash_pplan, :ring_buffer_capacity)
    end
  end

  # Lane Z5 court: 8 concurrent writers x 2000 pushes. The returned global seq
  # multiset must be exactly 16000 consecutive integers from its base — no
  # gaps, no duplicates. This is the exactly-once monotonic allocation proof
  # for the single-counter design (shard-stride allocation would show gaps
  # here under unequal shard drain).
  test "court: 8x2000 concurrent pushes allocate a dense, gap-free, duplicate-free seq range" do
    RingBuffer.init()
    num_writers = 8
    pushes_per_writer = 2000
    total = num_writers * pushes_per_writer

    seqs =
      1..num_writers
      |> Enum.map(fn w ->
        Task.async(fn ->
          for _ <- 1..pushes_per_writer do
            {:ok, seq} = RingBuffer.push("z5-court-#{w}", :step, :out, %{})
            seq
          end
        end)
      end)
      |> Enum.flat_map(&Task.await(&1, 30_000))

    assert length(seqs) == total
    assert length(Enum.uniq(seqs)) == total, "duplicate seqs allocated"

    sorted = Enum.sort(seqs)
    [base | rest] = sorted

    rest
    |> Enum.reduce(base, fn seq, prev ->
      assert seq == prev + 1, "gap in seq allocation: expected #{prev + 1}, got #{seq}"
      seq
    end)

    assert base >= 1
  end

  # Lane Z5 court: capacity evict stays correct under concurrent push — after
  # the sweep, no row exists at or below head - capacity, and read_batch never
  # returns an entry from below the floor even when the floor moved mid-push.
  test "court: capacity evict correct under concurrent push" do
    Application.put_env(:ash_pplan, :ring_buffer_capacity, 500)
    try do
      RingBuffer.init()

      1..4
      |> Enum.map(fn w ->
        Task.async(fn ->
          for _ <- 1..1000 do
            {:ok, _} = RingBuffer.push("z5-evict-#{w}", :step, :out, %{})
          end
        end)
      end)
      |> Enum.each(&Task.await(&1, 30_000))

      RingBuffer.evict_now()
      head = RingBuffer.head_seq()

      rows =
        :ets.tab2list(:ash_pplan_ring_buffer)
        |> Enum.filter(fn
          {:__seq_meta__, _, _} -> false
          {seq, _, _, _, _, _} when is_integer(seq) -> true
          _ -> false
        end)

      assert length(rows) <= 500
      assert Enum.all?(rows, fn {seq, _, _, _, _, _} -> seq > head - 500 end)

      window = RingBuffer.read_batch(1, 10_000)
      assert length(window) <= 500
      assert Enum.all?(window, fn {seq, _, _, _, _, _} -> seq > head - 500 end)
      assert window != []
    after
      Application.delete_env(:ash_pplan, :ring_buffer_capacity)
    end
  end

end

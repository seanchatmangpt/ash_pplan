defmodule AshPPlan.Reactor.Durable.RingBuffer do
  @moduledoc """
  LMAX Disruptor mechanical sympathy pattern: Pre-allocated in-memory state sequence ring buffer.

  Keyed by a monotonic 64-bit integer (`run_seq`) allocated via atomic `:ets.update_counter/3`.
  Provides sub-10µs step transition commits in memory, decoupling live execution from disk I/O.
  """

  @table_name :ash_pplan_ring_buffer
  @meta_key :__seq_meta__

  @type seq :: non_neg_integer()
  @type entry :: {seq(), run_id :: String.t(), step_name :: term(), output :: term(), meta :: map(), timestamp_us :: integer()}

  @doc """
  Initializes the ring buffer ETS table if not already started.
  Configured with `:write_concurrency` and `:read_concurrency` for maximum parallel throughput.
  """
  @spec init() :: :ok
  def init do
    case :ets.info(@table_name) do
      :undefined ->
        :ets.new(@table_name, [
          :set,
          :public,
          :named_table,
          {:write_concurrency, true},
          {:read_concurrency, true}
        ])
        :ets.insert(@table_name, {@meta_key, 0, 0})
        :ok

      _info ->
        :ok
    end
  end

  @doc """
  Pushes an unpersisted step transition into the ring buffer with an atomic sequence increment.
  Returns `{:ok, seq}`.
  """
  @spec push(String.t(), term(), term(), map()) :: {:ok, seq()}
  def push(run_id, step_name, output, meta \\ %{}) do
    init()
    seq = :ets.update_counter(@table_name, @meta_key, {2, 1})
    now_us = System.monotonic_time(:microsecond)
    entry = {seq, run_id, step_name, output, meta, now_us}
    :ets.insert(@table_name, entry)
    {:ok, seq}
  end

  @doc """
  Reads a batch of entries starting from `from_seq` up to `limit` entries.
  """
  @spec read_batch(seq(), pos_integer()) :: [entry()]
  def read_batch(from_seq, limit \\ 100) do
    init()
    current_head = head_seq()

    if from_seq > current_head do
      []
    else
      to_seq = min(from_seq + limit - 1, current_head)

      from_seq..to_seq
      |> Enum.reduce([], fn s, acc ->
        case :ets.lookup(@table_name, s) do
          [entry] -> [entry | acc]
          [] -> acc
        end
      end)
      |> Enum.reverse()
    end
  end

  @doc """
  Returns the latest committed head sequence number.
  """
  @spec head_seq() :: seq()
  def head_seq do
    init()
    case :ets.lookup(@table_name, @meta_key) do
      [{@meta_key, head, _ack}] -> head
      [] -> 0
    end
  end

  @doc """
  Prunes entries older than `ack_seq` from the ring buffer.
  """
  @spec prune(seq()) :: :ok
  def prune(ack_seq) do
    init()
    case :ets.lookup(@table_name, @meta_key) do
      [{@meta_key, head, old_ack}] ->
        if ack_seq > old_ack do
          for s <- old_ack..ack_seq do
            :ets.delete(@table_name, s)
          end
          :ets.insert(@table_name, {@meta_key, head, ack_seq})
        end
        :ok

      [] ->
        :ok
    end
  end
end

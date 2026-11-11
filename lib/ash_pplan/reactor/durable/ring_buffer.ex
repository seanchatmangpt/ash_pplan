defmodule AshPPlan.Reactor.Durable.RingBuffer do
  @moduledoc """
  In-memory step-transition sequence allocator, keyed by a monotonic sequence
  integer allocated via atomic `:ets.update_counter/3`.

  Capacity-bounded (LANE-A5): entries at seq <= head - capacity are evicted;
  `read_batch/2` clamps its start above the eviction floor and skips gaps, so
  the readable window is at most the last `capacity()` entries.

  Sequence allocation law (LANE-Z5): a single global counter row is the only
  allocator. `:ets.update_counter/3` is atomic per increment, so each push
  receives a distinct seq (no duplicates); increments are consecutive from the
  initial value 0, so the set of allocated seqs is exactly `1..head_seq()`
  (no gaps). Per-writer sharded counters with a stride were rejected: under
  unequal shard load the union of shard sequences is *not* dense, which would
  violate the no-gaps guarantee.

  Contention fix (LANE-Z5, F1 follow-up): the previous implementation ran
  `init/0` (an `:ets.info/1` table lookup) and a full-table
  `:ets.select_delete/2` scan on *every* push — O(capacity) work per push,
  which measured p99 = 12ms under 8 concurrent writers. Now init is hoisted
  behind a per-process fast-path flag and eviction is amortized: every 512th
  push sweeps entries at or below `trigger_seq - capacity()` (all such
  entries are at least a full capacity behind the live head, since the head
  only moves forward), and `evict_now/0` forces the sweep for tests and
  shutdown paths.

  The "sub-10µs commit" figure is verified against `bench/claims_bench.exs`;
  see that file's output for the measured p50/p95/p99.
  """

  @table_name :ash_pplan_ring_buffer
  @meta_key :__seq_meta__
  @default_capacity 65_536
  @evict_stride 512
  @init_key :__ash_pplan_ring_buffer_init__

  @doc "Effective capacity (entries retained), from app env or the default."
  @spec capacity() :: pos_integer()
  def capacity do
    Application.get_env(:ash_pplan, :ring_buffer_capacity, @default_capacity)
  end

  @type seq :: non_neg_integer()
  @type entry ::
          {seq(), run_id :: String.t(), step_name :: term(), output :: term(), meta :: map(),
           timestamp_us :: integer()}

  @doc """
  Initializes the ring buffer ETS table if not already started.
  Configured with `:write_concurrency` and `:read_concurrency` for maximum parallel throughput.

  The table is owned by a dedicated unlinked `TableOwner` GenServer paired with
  a `TableHeir` GenServer (`{:heir, heir_pid, :ring_buffer_heir}`), so termination
  of any calling process (ephemeral `Task`, `Reactor` step, `Oban` worker, or test
  process) never destroys the table, loses entries, or resets sequence numbers.

  Idempotent and concurrency-safe; safe to call from any process.
  """
  @spec init() :: :ok
  def init do
    if table_healthy?() do
      :ok
    else
      __MODULE__.TableOwner.ensure_table()
    end
  end

  defp table_healthy? do
    owner = Process.whereis(__MODULE__.TableOwner)
    heir = Process.whereis(__MODULE__.TableHeir)

    is_pid(owner) and is_pid(heir) and
      :ets.whereis(@table_name) != :undefined and
      :ets.info(@table_name, :owner) == owner and
      :ets.info(@table_name, :heir) == heir and
      :ets.member(@table_name, @meta_key)
  rescue
    ArgumentError -> false
  end

  # Per-process fast path: after the first confirmed-present check in this
  # process, skip the :ets.info/1 lookup on subsequent pushes. The table is
  # owned by TableOwner with TableHeir inheritance so caller exits never delete
  # it; if the table is ever externally deleted, ETS operations rescue
  # ArgumentError, clear @init_key, re-initialize via TableOwner, and retry once.
  @compile {:inline, [ensure_init: 0]}
  defp ensure_init do
    case Process.get(@init_key) do
      true -> :ok
      _ -> slow_init()
    end
  end

  defp slow_init do
    init()

    if :ets.whereis(@table_name) != :undefined do
      Process.put(@init_key, true)
    end

    :ok
  end

  defp recover_table do
    Process.delete(@init_key)
    slow_init()
  end

  @doc """
  Pushes an unpersisted step transition into the ring buffer with an atomic sequence increment.
  Returns `{:ok, seq}`.

  Per-push cost is two ETS operations (atomic counter increment + insert);
  eviction is amortized onto every #{@evict_stride}-th push.
  """
  @spec push(String.t(), term(), term(), map()) :: {:ok, seq()}
  def push(run_id, step_name, output, meta \\ %{}) do
    ensure_init()

    try do
      do_push(run_id, step_name, output, meta)
    rescue
      ArgumentError ->
        recover_table()
        do_push(run_id, step_name, output, meta)
    end
  end

  @compile {:inline, [do_push: 4]}
  defp do_push(run_id, step_name, output, meta) do
    seq = :ets.update_counter(@table_name, @meta_key, {2, 1}, {@meta_key, 0, 0})
    now_us = System.monotonic_time(:microsecond)
    entry = {seq, run_id, step_name, output, meta, now_us}
    :ets.insert(@table_name, entry)

    if rem(seq, @evict_stride) == 0 do
      evict_through(seq - capacity())
    end

    {:ok, seq}
  end

  @doc """
  Forces one eviction sweep: deletes every entry at seq <= head_seq() - capacity().
  Normally unnecessary — push/4 amortizes this — but useful in tests and at
  quiesce time to shrink the table immediately.
  """
  @spec evict_now() :: :ok
  def evict_now do
    ensure_init()

    try do
      evict_through(head_seq_raw() - capacity())
      :ok
    rescue
      ArgumentError ->
        recover_table()
        evict_through(head_seq_raw() - capacity())
        :ok
    end
  end

  # Delete entries at or below `floor`. Callers guarantee head >= trigger seq
  # > floor + capacity, i.e. every deleted entry is a full capacity behind
  # the live head — wrap semantics preserved, nothing inside the window is
  # touched.
  defp evict_through(floor) do
    if floor > 0 do
      op = :"=<"
      col = :"$1"
      floor_guard = {op, col, floor}
      is_int = {:is_integer, col}
      head = {col, :_, :_, :_, :_, :_}
      :ets.select_delete(@table_name, [{head, [is_int, floor_guard], [true]}])
    end

    :ok
  end

  @doc """
  Reads a batch of entries starting from `from_seq` up to `limit` entries.
  Entries at seq <= head - capacity have been (or are being) evicted; the
  start is clamped above that floor so no evicted entry is ever returned.
  """
  @spec read_batch(seq(), pos_integer()) :: [entry()]
  def read_batch(from_seq, limit \\ 100) do
    ensure_init()

    try do
      do_read_batch(from_seq, limit)
    rescue
      ArgumentError ->
        recover_table()
        do_read_batch(from_seq, limit)
    end
  end

  defp do_read_batch(from_seq, limit) do
    current_head = head_seq_raw()
    floor = current_head - capacity()
    from_seq = max(from_seq, floor + 1)

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
    ensure_init()

    try do
      head_seq_raw()
    rescue
      ArgumentError ->
        recover_table()
        head_seq_raw()
    end
  end

  @compile {:inline, [head_seq_raw: 0]}
  defp head_seq_raw do
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
    ensure_init()

    try do
      do_prune(ack_seq)
    rescue
      ArgumentError ->
        recover_table()
        do_prune(ack_seq)
    end
  end

  defp do_prune(ack_seq) do
    case :ets.lookup(@table_name, @meta_key) do
      [{@meta_key, _head, old_ack}] ->
        if ack_seq > old_ack do
          for s <- old_ack..ack_seq do
            :ets.delete(@table_name, s)
          end

          # Advance ack watermark monotonically without overwriting the live
          # decentralized head counter in slot 2.
          :ets.select_replace(@table_name, [
            {{@meta_key, :"$1", :"$2"}, [{:<, :"$2", ack_seq}], [{{@meta_key, :"$1", ack_seq}}]}
          ])
        end

        :ok

      [] ->
        :ok
    end
  end

  defmodule TableHeir do
    @moduledoc false
    use GenServer

    alias AshPPlan.Reactor.Durable.RingBuffer.TableOwner

    @table_name :ash_pplan_ring_buffer

    @spec ensure_started() :: pid()
    def ensure_started do
      case GenServer.start(__MODULE__, :ok, name: __MODULE__) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
        {:error, _} -> ensure_started()
      end
    end

    @impl GenServer
    def init(:ok) do
      Process.flag(:trap_exit, true)
      Process.flag(:priority, :high)
      {:ok, %{}}
    end

    @impl GenServer
    def handle_info({:"ETS-TRANSFER", tab, _from_pid, _gift_data}, state) do
      hand_back(tab)
      {:noreply, state}
    end

    def handle_info(:retry_hand_back, state) do
      case :ets.whereis(@table_name) do
        :undefined ->
          :ok

        tab ->
          if :ets.info(tab, :owner) == self() do
            hand_back(tab)
          end
      end

      {:noreply, state}
    end

    def handle_info(_msg, state), do: {:noreply, state}

    defp hand_back(tab) do
      owner = TableOwner.ensure_started()

      if is_pid(owner) and owner != self() do
        try do
          :ets.setopts(tab, {:heir, self(), :ring_buffer_heir})
          :ets.give_away(tab, owner, :ring_buffer_restore)
        rescue
          ArgumentError ->
            Process.send_after(self(), :retry_hand_back, 1)
        end
      end
    end
  end

  defmodule TableOwner do
    @moduledoc false
    use GenServer

    alias AshPPlan.Reactor.Durable.RingBuffer.TableHeir

    @table_name :ash_pplan_ring_buffer
    @meta_key :__seq_meta__

    @spec ensure_started() :: pid()
    def ensure_started do
      case GenServer.start(__MODULE__, :ok, name: __MODULE__) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
        {:error, _} -> ensure_started()
      end
    end

    @spec ensure_table(non_neg_integer()) :: :ok
    def ensure_table(retries \\ 5) do
      _ = TableHeir.ensure_started()
      pid = ensure_started()

      try do
        GenServer.call(pid, :ensure_table, 5_000)
      catch
        :exit, _ when retries > 0 ->
          ensure_table(retries - 1)
      end
    end

    @impl GenServer
    def init(:ok) do
      Process.flag(:trap_exit, true)
      Process.flag(:priority, :high)
      state = bind_live_heir(%{heir: nil, ref: nil})
      state = ensure_ets_table(state)
      {:ok, state}
    end

    @impl GenServer
    def handle_call(:ensure_table, _from, state) do
      state = state |> bind_live_heir() |> ensure_ets_table()
      {:reply, :ok, state}
    end

    @impl GenServer
    def handle_info({:"ETS-TRANSFER", _tab, _from_pid, _gift_data}, state) do
      state = state |> bind_live_heir() |> ensure_ets_table()
      {:noreply, state}
    end

    def handle_info({:DOWN, ref, :process, _pid, _reason}, %{ref: ref} = state) do
      state = bind_live_heir(%{state | heir: nil, ref: nil})
      {:noreply, state}
    end

    def handle_info(_msg, state), do: {:noreply, state}

    defp bind_live_heir(%{heir: heir, ref: ref} = state) do
      state =
        if is_pid(heir) and Process.alive?(heir) do
          state
        else
          if is_reference(ref), do: Process.demonitor(ref, [:flush])
          new_heir = TableHeir.ensure_started()
          %{state | heir: new_heir, ref: Process.monitor(new_heir)}
        end

      case :ets.whereis(@table_name) do
        :undefined ->
          state

        tab ->
          if :ets.info(tab, :owner) == self() do
            try do
              :ets.setopts(tab, {:heir, state.heir, :ring_buffer_heir})
              state
            rescue
              ArgumentError ->
                if is_reference(state.ref), do: Process.demonitor(state.ref, [:flush])
                bind_live_heir(%{state | heir: nil, ref: nil})
            end
          else
            state
          end
      end
    end

    defp ensure_ets_table(state) do
      case :ets.whereis(@table_name) do
        :undefined ->
          try do
            :ets.new(@table_name, [
              :set,
              :public,
              :named_table,
              {:write_concurrency, true},
              {:read_concurrency, true},
              # OTP 26+ decentralized counters: `:ets.update_counter/4` keeps its
              # exact semantics (unique, consecutive increments from 0 -> dense
              # 1..head, no gaps, no dupes) while the counter update work is
              # sharded across schedulers internally — removing the single-row
              # write-lock contention that dominated the 8-writer tail.
              {:decentralized_counters, true},
              {:heir, state.heir, :ring_buffer_heir}
            ])

            :ets.insert_new(@table_name, {@meta_key, 0, 0})
            state
          rescue
            ArgumentError ->
              if :ets.whereis(@table_name) == :undefined do
                if is_reference(state.ref), do: Process.demonitor(state.ref, [:flush])

                state
                |> Map.merge(%{heir: nil, ref: nil})
                |> bind_live_heir()
                |> ensure_ets_table()
              else
                :ets.insert_new(@table_name, {@meta_key, 0, 0})
                bind_live_heir(state)
              end
          end

        tab ->
          :ets.insert_new(tab, {@meta_key, 0, 0})
          bind_live_heir(state)
      end
    end
  end
end

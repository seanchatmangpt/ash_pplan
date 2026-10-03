defmodule AshPPlan.Standing.Cached do
  @max 256

  @moduledoc """
  ETS-backed memo for `AshPPlan.Standing.receipt/2` results, keyed on evidence
  identity: a sha256 over `term_to_binary({run, opts})` -- the exact inputs of the
  call, content-addressed, no wall clock. Same inputs reproduce the same key and
  the receipt itself is deterministic, so a cache hit is byte-identical to a
  recomputation.

  Bounded (LRU, default #{@max} entries): the least-recently-used entry is evicted
  when the table is full. The bound is concurrency-safe: all inserts serialize on a
  dedicated eviction claim, and inside it the evictor loops (over an `:ordered_set`
  tick index) until the table is under capacity before inserting — concurrent
  inserters cannot bypass the bound. `receipt/2` semantics are unchanged; this
  module only wraps it. Errors are cached too (a malformed run is deterministically
  refused).

  Cold-key fills are single-flight: concurrent callers of one key race an
  `:ets.insert_new/2` claim, exactly one computes, the rest spin on the stored
  value. A crashed or wedged claim holder costs at most one extra compute: on
  flight timeout a waiter takes over the stale claim (one bounded extension
  first if the holder is still alive), and the takeover race picks a single new
  owner. Because the receipt is deterministic, any recomputation is correct —
  the flight only exists to save the work, never to change the answer.
  """

  @table :ash_pplan_standing_receipt_cache
  @index :ash_pplan_standing_receipt_cache_lru_index
  @claims :ash_pplan_standing_receipt_cache_claims
  @evict_lock :__ash_pplan_standing_receipt_cache_evict_lock__
  @default_flight_timeout_ms 5_000
  @flight_poll_ms 1
  @evict_lock_spin_tries 20_000

  @doc "Cache bound."
  def max_entries, do: @max

  @doc """
  `fun.()` on identity miss, cached result on hit. Returns
  `{:ok, %Receipt{}} | {:error, map()}` exactly as the wrapped call would.

  At most one concurrent caller per cold key runs `fun.()` under the common
  case (no crash/timeout); the rest block on the value.
  """
  @spec get_or_compute(map(), keyword(), (-> term())) :: term()
  def get_or_compute(run, opts, fun) do
    key = identity(run, opts)

    case lookup(key) do
      {:ok, value} ->
        value

      :miss ->
        ensure_tables()

        if :ets.insert_new(@claims, {key, {:computing, self()}}) do
          compute_and_store(key, fun)
        else
          await_flight(key, fun, flight_deadline())
        end
    end
  end

  defp compute_and_store(key, fun) do
    try do
      value = fun.()
      insert(key, value)
      value
    after
      :ets.delete(@claims, key)
    end
  end

  # Loser: spin on the stored value until the winner publishes. On timeout the
  # claim holder is inspected: alive holders get one bounded extension, then any
  # waiter (or a crashed holder's stale claim) is taken over — the stale claim is
  # deleted and a fresh claim race decides the one new flight owner. Losers that
  # lose the takeover race go back to spinning on the value, so a crashed or
  # wedged holder costs at most one extra compute, never N.
  defp await_flight(key, fun, deadline, extensions \\ 0) do
    case lookup(key) do
      {:ok, value} ->
        value

      :miss ->
        now = System.monotonic_time()

        cond do
          now < deadline ->
            Process.send_after(self(), :__cached_flight_poll__, @flight_poll_ms)

            receive do
              :__cached_flight_poll__ -> await_flight(key, fun, deadline, extensions)
            end

          true ->
            case :ets.lookup(@claims, key) do
              [{^key, {:computing, pid}}] when is_pid(pid) and pid != self() ->
                if Process.alive?(pid) and extensions < 1 do
                  await_flight(key, fun, now + flight_deadline_offset(), extensions + 1)
                else
                  take_over(key, fun)
                end

              _ ->
                take_over(key, fun)
            end
        end
    end
  end

  defp take_over(key, fun) do
    # clear the stale/abdicated claim; the insert_new race below picks one owner
    :ets.delete(@claims, key)

    if :ets.insert_new(@claims, {key, {:computing, self()}}) do
      compute_and_store(key, fun)
    else
      # another waiter took over; go back to waiting on their flight
      await_flight(key, fun, flight_deadline(), 0)
    end
  end

  defp flight_deadline,
    do: System.monotonic_time() + flight_deadline_offset()

  defp flight_deadline_offset,
    do: System.convert_time_unit(flight_timeout_ms(), :millisecond, :native)

  defp flight_timeout_ms,
    do: Application.get_env(:ash_pplan, :standing_flight_timeout_ms, @default_flight_timeout_ms)

  @doc "Deterministic evidence identity: sha256 of the exact `{run, opts}` terms."
  @spec identity(map(), keyword()) :: binary()
  def identity(run, opts), do: :crypto.hash(:sha256, :erlang.term_to_binary({run, opts}))

  @doc "Drop every cached entry (and any in-flight claims)."
  def clear do
    ensure_tables()
    :ets.delete_all_objects(@table)
    :ets.delete_all_objects(@index)
    :ets.delete_all_objects(@claims)
    :ok
  end

  @doc "Number of cached entries."
  def size, do: :ets.info(@table, :size) || 0

  defp ensure_tables do
    owner = ensure_owner()
    ref = make_ref()
    send(owner, {:ensure_tables, self(), ref})

    receive do
      {^ref, :ok} -> :ok
    end
  end

  # Named ETS tables must outlive the processes that first touch them (under
  # ExUnit every test is its own process; a table owned by a finished test dies
  # with it, and a later clear/lookup then hits a dead table). A dedicated
  # long-lived owner process owns all three tables; creation is synchronous via
  # a reply so no caller can observe a half-initialized table set.
  @owner_name :ash_pplan_standing_receipt_cache_owner

  defp ensure_owner do
    case Process.whereis(@owner_name) do
      nil ->
        pid = spawn(fn -> owner_init() end)

        try do
          Process.register(pid, @owner_name)
        rescue
          ArgumentError ->
            # Lost the race; another owner is registered and has already
            # created the tables (it creates before we could register... its
            # creation happens on first :ensure_tables message).
            Process.exit(pid, :kill)
        end

        Process.whereis(@owner_name)

      pid ->
        pid
    end
  end

  defp owner_init do
    owner_loop()
  end

  defp owner_loop do
    receive do
      {:ensure_tables, requester, ref} ->
        create_missing_tables()
        send(requester, {ref, :ok})
        owner_loop()
    end
  end

  defp create_missing_tables do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
    end

    if :ets.whereis(@claims) == :undefined do
      :ets.new(@claims, [:set, :named_table, :public])
    end

    if :ets.whereis(@index) == :undefined do
      :ets.new(@index, [:ordered_set, :named_table, :public])
    end

    :ok
  end

  defp lookup(key) do
    ensure_tables()

    case :ets.lookup(@table, key) do
      [{^key, value, _old_tick}] ->
        # LRU touch: re-stamp under the current clock tick. The touch does not
        # grow the table, so it never takes the eviction lock; the old index
        # entry is removed best-effort (a racing evictor deletes the same key).
        new_tick = tick()
        index_delete_key(key)
        :ets.insert(@index, {{new_tick, key}})
        :ets.insert(@table, {key, value, new_tick})
        {:ok, value}

      [] ->
        :miss
    end
  end

  defp insert(key, value) do
    ensure_tables()

    case :ets.lookup(@table, key) do
      [{^key, _, _}] ->
        # Existing key: a re-stamp, no growth — same path as an LRU touch.
        new_tick = tick()
        index_delete_key(key)
        :ets.insert(@index, {{new_tick, key}})
        :ets.insert(@table, {key, value, new_tick})

      [] ->
        with_evict_lock(fn ->
          # Bounded under concurrency: the lock serializes every growing insert,
          # and the loop evicts until strictly under capacity before inserting,
          # so the table can never end an insert above the bound.
          evict_until_under_bound()
          new_tick = tick()
          :ets.insert(@index, {{new_tick, key}})
          :ets.insert(@table, {key, value, new_tick})
        end)
    end

    :ok
  end

  # Evict least-recently-stamped entries (index order == tick order) until the
  # main table is strictly below capacity.
  defp evict_until_under_bound do
    if :ets.info(@table, :size) >= @max do
      evict_oldest()
      evict_until_under_bound()
    end

    :ok
  end

  defp evict_oldest do
    case :ets.first(@index) do
      :"$end_of_table" ->
        # Reconcile-back: a touch racing an evictor can resurrect a main entry
        # whose index stamp was already consumed. Such an orphan is still a real
        # cached entry, so if the table is at capacity with an empty index, purge
        # by scanning (the table is capped at #{@max}) instead of looping forever.
        case :ets.tab2list(@table) do
          [] ->
            :ok

          entries ->
            {key, _value, _tick} = Enum.min_by(fn {_k, _v, t} -> t end, entries)
            index_delete_key(key)
            :ets.delete(@table, key)
            :ok
        end

      {_tick, key} ->
        # Drop every index entry for the key (a racing touch may have left a
        # newer stamp) plus the main entry, whatever its current tick.
        index_delete_key(key)
        :ets.delete(@table, key)
        :ok
    end
  end

  defp index_delete_key(key) do
    :ets.match_delete(@index, {{:_, key}})
  end

  # The eviction lock serializes growing inserts so the LRU bound cannot be
  # bypassed by concurrent inserters (the old check-then-delete overshot: 16
  # concurrent inserts observed 441 entries against a 256 bound). The critical
  # section is short (one insert + the evictions it needs), so a bounded spin
  # with a steal-on-wedge fallback is sufficient — a stale lock holder costs
  # one stolen turn, never a hang.
  defp with_evict_lock(fun), do: with_evict_lock_after(0, fun)

  # Re-entry point that carries the backoff counter so contended spins make
  # progress (sleep after 64 tries, steal after @evict_lock_spin_tries).
  defp with_evict_lock_after(tries, fun) do
    if :ets.insert_new(@claims, {@evict_lock, self()}) do
      try do
        fun.()
      after
        :ets.delete(@claims, @evict_lock)
      end
    else
      case :ets.lookup(@claims, @evict_lock) do
        [{@evict_lock, pid}] when is_pid(pid) and pid != self() ->
          if Process.alive?(pid) do
            evict_lock_backoff(fun, tries)
          else
            steal_evict_lock(fun)
          end

        _ ->
          with_evict_lock_after(0, fun)
      end
    end
  end

  defp steal_evict_lock(fun) do
    :ets.insert(@claims, {@evict_lock, self()})

    try do
      fun.()
    after
      :ets.delete(@claims, @evict_lock)
    end
  end

  defp evict_lock_backoff(fun, tries) when tries < @evict_lock_spin_tries do
    if tries > 64, do: Process.sleep(1)
    with_evict_lock_after(tries + 1, fun)
  end

  defp evict_lock_backoff(fun, _tries) do
    # Wedged holder (alive but stuck): steal the lock and proceed.
    :ets.insert(@claims, {@evict_lock, self()})

    try do
      fun.()
    after
      :ets.delete(@claims, @evict_lock)
    end
  end

  defp tick, do: System.monotonic_time()
end

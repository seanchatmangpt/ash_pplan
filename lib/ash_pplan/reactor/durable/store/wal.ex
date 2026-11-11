defmodule AshPPlan.Reactor.Durable.Store.Wal do
  @moduledoc """
  Append-only framed Write-Ahead Log (WAL) store.

  Implements `AshPPlan.Reactor.Durable.Store`. Writes framed chunks as
  `<<len::32, crc32::32, payload::binary>>`; the in-memory index is hydrated on
  `open/1` by replaying every frame.

  ## Integrity policy: refuse-or-tail-truncate

  - A frame whose CRC32 mismatches (or whose term is not a decodable known frame) is an
    integrity failure MID-STREAM: `open/1` returns `{:error, {:wal_integrity, detail}}` -
    never a silent divergence between the durable log and the rebuilt index.
  - A torn append tail (a final frame whose header advertises more bytes than remain) is
    ordinary crash recovery: the file is truncated at the last good frame and open proceeds.
    A len-flip mid-stream is indistinguishable from a torn tail, so that corruption class
    truncates instead of refusing - this boundary is documented, not hidden.

  ## Concurrency

  Read-modify-write operations (`claim`, `record`, `consume_signal`, `park`, undo claims)
  run under a per-row CAS lock (`{:lock, scope}` ETS row via `insert_new`; bounded retries;
  a lock older than 30s is stolen atomically, so a dead holder cannot deadlock the row).
  Claims and consumes are therefore single-winner; V5 P4's double-grant is closed.

  ## Batched append writer (Z6)

  Appends go through a per-store writer process (`__MODULE__.Writer`) holding the file
  device OPEN (`:raw + :binary + :append`); frames accumulate in a bounded server-state
  buffer and flush as ONE iodata write per batch. Flush triggers: (a) 32 buffered frames,
  (b) a 25ms deadline, (c) any read/reopen/close (durability-before-read law) - and every
  ack-class append is itself a flush of its whole batch (mailbox-drain coalescing: frames
  already queued behind the writer's current message join the same write).

  ## Callback durability classes (ack vs fire-and-forget)

  - **Ack-class (ALL mutating callbacks today)**: `start_run`, `claim`, `release_claim`,
    `renew_claim`, `record`, `mark_undone`, `transition`, `deliver_signal`,
    `consume_signal`, `park`, `release`, `release_all` - the caller blocks until its frame
    (and every frame coalesced into the same batch) is written to the open file device.
    Reply-after-flush preserves the pre-Z6 sync-before-reply semantics exactly. `record`
    and `transition` are additionally the **sync-before-side-effect law** callbacks: their
    replies gate engine progress, so they can never reply pre-flush.
  - **Fire-and-forget: NONE today.** The writer exposes an async (`cast`) path with the
    N-frame/25ms triggers for future non-ack callers; no store callback uses it. The crash
    window below applies only to that path.
  - **Crash window**: a kill between accumulate and flush loses only unflushed CAST frames.
    No acked write is ever lost: an acked frame was in a completed flush. (F1's 338/338
    kill-mid-burst pattern asserts this.)

  ## Divergences (loud)

  - **NONE.** The former undo_once one-law divergence is resolved: the
    generated conformance law `law_undo_once/3`
    (`test/support/durable/store_conformance.ex`) was regenerated to the
    `Store` behaviour contract (volatile claim followed by `mark_undone/4`,
    at-least-once undo), and `Wal` passes the full law set with no registered
    divergence — 19/0 on `test/durable/store_conformance_wal_test.exs`
    (FA2 re-run 2026-11-07; the `Ets` and `Dets` courts pass the same law set).
  - Volatile rows (`{:lock, _}`, `{:undo_claim, _}`, `{:wal_seq}`) share the index table but
    are never framed; `{:wal_seq}` is re-derived from the replayed maximum seq on open.
  """

  @behaviour AshPPlan.Reactor.Durable.Store

  alias AshPPlan.Reactor.Durable.{Checkpoint, Clock, Record, Signal, Status, Store, Waiter}
  alias AshPPlan.Reactor.Durable.Store.Wal.Writer

  defstruct [:path, :index_table, :writer]

  @type t :: %__MODULE__{
          path: String.t(),
          index_table: :ets.tid(),
          writer: pid() | nil
        }

  # Row locks: CAS via insert_new on a {:lock, scope} row; a lock older than @lock_stale_ms
  # is stolen atomically (dead holder), otherwise bounded retry.
  @lock_wait_ms 5_000
  @lock_stale_ms 30_000

  # Volatile undo claims expire on this lease (measured from claim_undo's `now`), so a
  # rollback worker crash between claim and mark_undone re-runs the undo (at-least-once)
  # instead of deadlocking the checkpoint behind a leaked claim.
  @undo_claim_lease_ms 30_000

  @doc "Opens or initializes a WAL store at `path`."
  @spec open(String.t()) :: {:ok, t()} | {:error, {:wal_integrity, detail :: term()}}
  def open(path) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    index_table = :ets.new(:wal_index, [:set, :public, {:read_concurrency, true}])

    wal = %__MODULE__{path: path, index_table: index_table}

    case hydrate_index(wal) do
      :ok ->
        :ok = hydrate_seq(wal)
        {:ok, writer} = Writer.start_link(path)
        {:ok, %__MODULE__{wal | writer: writer}}

      {:error, detail} ->
        :ets.delete(index_table)
        {:error, detail}
    end
  end

  @doc "Closes the WAL store file and clears index."
  def close(%__MODULE__{index_table: table, writer: writer}) do
    if writer && Process.alive?(writer) do
      Writer.flush_and_stop(writer)
    end

    try do
      :ets.delete(table)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  # ===================================================================
  # Row lock (CAS)
  # ===================================================================

  # Serializes read-modify-write on one logical row. Winner: insert_new the lock row, run
  # the body, delete the lock in `after`. Loser: bounded retry; a lock older than
  # @lock_stale_ms is stolen atomically (select_delete on the stale stamp). Exhaustion is a
  # typed error - never a silent :taken.
  defp with_row_lock(wal, scope, fun, deadline \\ nil)

  defp with_row_lock(_wal, _scope, _fun, 0), do: {:error, :wal_contention}

  defp with_row_lock(%__MODULE__{index_table: table} = wal, scope, fun, deadline) do
    key = {:lock, scope}
    now = System.monotonic_time(:millisecond)
    deadline = deadline || now + @lock_wait_ms

    ref = make_ref()

    if :ets.insert_new(table, {key, ref, now}) do
      # refresh the stamp post-acquire: `now` may predate a deschedule, and a freshly
      # acquired lock must not look stealable (double-execution guard)
      :ets.update_element(table, key, {3, System.monotonic_time(:millisecond)})

      try do
        fun.()
      after
        case :ets.lookup(table, key) do
          [{^key, ^ref, _}] -> :ets.delete(table, key)
          _ -> :ok
        end
      end
    else
      if now >= deadline do
        {:error, :wal_contention}
      else
        case :ets.lookup(table, key) do
          [{^key, _ref, stamp}] when now - stamp > @lock_stale_ms ->
            # stale takeover: atomic select_delete; only one stealer removes the stale row
            op = :<
            col = :"$3"
            guard = {op, col, now - @lock_stale_ms}
            head = {key, :_, col}
            :ets.select_delete(table, [{head, [guard], [true]}])

          _ ->
            :ok
        end

        with_row_lock(wal, scope, fun, deadline)
      end
    end
  end

  # Shared monotonic seq counter (runs, checkpoints, signals). Atomic via update_counter;
  # the row is volatile and re-derived from the replayed max seq on open (hydrate_seq/1).
  defp next_seq(table) do
    :ets.update_counter(table, {:wal_seq}, {2, 1}, {{:wal_seq}, 0})
  end

  # ===================================================================
  # Store Behaviour Callbacks
  # ===================================================================

  @impl Store
  def start_run(%__MODULE__{index_table: table} = wal, attrs) do
    id = Map.fetch!(attrs, :id)

    with_row_lock(wal, {:run, id}, fn ->
      case :ets.lookup(table, {:run, id}) do
        [{_, _existing}] ->
          {:error, :exists}

        [] ->
          {parent_id, parent_signal} =
            case Map.get(attrs, :parent) do
              {pid, sig} -> {pid, sig}
              _ -> {nil, nil}
            end

          base =
            attrs
            |> Map.take(Map.keys(Map.from_struct(%Record{id: nil})))
            |> Map.drop([:id, :version, :seq])

          record =
            struct!(
              Record,
              Map.merge(base, %{
                id: id,
                seq: next_seq(table),
                version: 1,
                parent_id: parent_id,
                parent_signal: parent_signal
              })
            )

          append_frame(wal, {:start_run, record})
          :ets.insert(table, {{:run, id}, record})
          {:ok, record}
      end
    end)
  end

  # Durability-before-read law: any read forces the writer to drain its buffer first, so a
  # read can never observe less durable state than a prior write observed. Reads still
  # serve from the in-memory index (which is always ahead of-or-equal to the file).
  defp flush_before_read(%__MODULE__{writer: writer}) when is_pid(writer) do
    Writer.flush(writer)
    :ok
  end

  defp flush_before_read(_wal), do: :ok

  @impl Store
  def get_run(%__MODULE__{index_table: table} = wal, id) do
    flush_before_read(wal)

    case :ets.lookup(table, {:run, id}) do
      [{_, record}] -> record
      [] -> nil
    end
  end

  @impl Store
  def list_runs(%__MODULE__{index_table: table} = wal) do
    flush_before_read(wal)
    match_spec = [{{{:run, :_}, :"$1"}, [], [:"$1"]}]
    table |> :ets.select(match_spec) |> Enum.sort_by(& &1.seq)
  end

  @impl Store
  def claim(%__MODULE__{index_table: table} = wal, id, claimer, lease_ms, now) do
    with_row_lock(wal, {:run, id}, fn ->
      case :ets.lookup(table, {:run, id}) do
        [{_, %Record{status: status}}] when status in [:completed, :failed, :cancelled] ->
          :taken

        [{_, rec}] ->
          if claimable?(rec, claimer, now) do
            until = DateTime.add(now, lease_ms, :millisecond)

            updated = %{
              rec
              | lease_until: until,
                lease_ms: lease_ms,
                claimed_by: claimer,
                claimed_at: now
            }

            append_frame(wal, {:claim, id, claimer, DateTime.to_unix(until, :millisecond), now})
            :ets.insert(table, {{:run, id}, updated})
            {:ok, updated}
          else
            :taken
          end

        [] ->
          :taken
      end
    end)
  end

  # The lease lives on the record: claimed + nil `lease_until` fails CLOSED (never claimable
  # by another claimer). Mirrors Ets.claimable?/3.
  defp claimable?(%Record{claimed_at: nil}, _claimer, _now), do: true

  defp claimable?(%Record{claimed_by: by}, claimer, _now)
       when not is_nil(claimer) and by == claimer,
       do: true

  defp claimable?(%Record{lease_until: nil}, _claimer, _now), do: false

  defp claimable?(%Record{lease_until: until}, _claimer, now),
    do: DateTime.compare(now, until) != :lt

  @impl Store
  def release_claim(%__MODULE__{index_table: table} = wal, id, claimer) do
    with_row_lock(wal, {:run, id}, fn ->
      case :ets.lookup(table, {:run, id}) do
        [{_, %Record{claimed_by: ^claimer} = rec}] ->
          updated = %{rec | lease_until: nil, lease_ms: nil, claimed_by: nil, claimed_at: nil}
          append_frame(wal, {:release_claim, id})
          :ets.insert(table, {{:run, id}, updated})
          :ok

        _ ->
          :ok
      end
    end)
  end

  @impl Store
  def renew_claim(%__MODULE__{index_table: table} = wal, id, claimer, lease_ms) do
    now = Clock.now()
    until = DateTime.add(now, lease_ms, :millisecond)

    with_row_lock(wal, {:run, id}, fn ->
      case :ets.lookup(table, {:run, id}) do
        [{_, %Record{claimed_by: ^claimer} = rec}] ->
          updated = %{rec | lease_until: until, lease_ms: lease_ms}
          append_frame(wal, {:renew_claim, id, claimer, DateTime.to_unix(until, :millisecond)})
          :ets.insert(table, {{:run, id}, updated})
          {:ok, updated}

        _ ->
          :taken
      end
    end)
  end

  @impl Store
  def record(%__MODULE__{index_table: table} = wal, run_id, step_key, label, output, meta) do
    with_row_lock(wal, {:run, run_id}, fn ->
      case :ets.lookup(table, {:checkpoint, run_id, step_key}) do
        [{_, standing}] ->
          {:ok, standing}

        [] ->
          case :ets.lookup(table, {:run, run_id}) do
            [{_, %Record{status: status}}] when status in [:completed, :failed, :cancelled] ->
              {:error, :terminal}

            [{_, %Record{status: :cancelling}}] ->
              {:error, :cancelling}

            _ ->
              cp = %Checkpoint{
                run_id: run_id,
                step_key: step_key,
                label: label,
                name: Map.get(meta, :name),
                output: output,
                impl: Map.get(meta, :impl),
                args: Map.get(meta, :args),
                seq: next_seq(table)
              }

              append_frame(wal, {:checkpoint, cp})
              :ets.insert(table, {{:checkpoint, run_id, step_key}, cp})
              {:ok, cp}
          end
      end
    end)
  end

  @impl Store
  def checkpoints(%__MODULE__{index_table: table} = wal, run_id) do
    flush_before_read(wal)
    match_spec = [{{{:checkpoint, run_id, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}]
    Map.new(:ets.select(table, match_spec))
  end

  @impl Store
  def standing(%__MODULE__{index_table: table} = wal, run_id) do
    flush_before_read(wal)

    match_spec = [
      {{{:checkpoint, run_id, :_}, :"$1"}, [{:==, {:map_get, :undone_at, :"$1"}, nil}], [:"$1"]}
    ]

    table |> :ets.select(match_spec) |> Enum.sort_by(& &1.seq)
  end

  @impl Store
  def claim_undo(%__MODULE__{index_table: table} = wal, run_id, step_key, now) do
    with_row_lock(wal, {:undo, run_id, step_key}, fn ->
      case :ets.lookup(table, {:checkpoint, run_id, step_key}) do
        [{_, %Checkpoint{undone_at: nil} = cp}] ->
          key = {:undo_claim, run_id, step_key}
          now_ms = DateTime.to_unix(now, :millisecond)

          case :ets.lookup(table, key) do
            [{_, expires}] when expires > now_ms ->
              :taken

            _ ->
              :ets.insert(table, {key, now_ms + @undo_claim_lease_ms})
              {:ok, cp}
          end

        _ ->
          :taken
      end
    end)
  end

  @impl Store
  def mark_undone(%__MODULE__{index_table: table} = wal, run_id, step_key, now) do
    with_row_lock(wal, {:undo, run_id, step_key}, fn ->
      case :ets.lookup(table, {:checkpoint, run_id, step_key}) do
        [{_, cp}] ->
          updated = %{cp | undone_at: now}
          append_frame(wal, {:checkpoint_undone, run_id, step_key, now})
          :ets.insert(table, {{:checkpoint, run_id, step_key}, updated})
          :ets.delete(table, {:undo_claim, run_id, step_key})
          {:ok, updated}

        [] ->
          {:error, :not_found}
      end
    end)
  end

  @impl Store
  def release_undo(%__MODULE__{index_table: table}, run_id, step_key) do
    :ets.delete(table, {:undo_claim, run_id, step_key})
    :ok
  end

  @impl Store
  def transition(%__MODULE__{index_table: table} = wal, run_id, from, to_status, attrs) do
    with_row_lock(wal, {:run, run_id}, fn ->
      case :ets.lookup(table, {:run, run_id}) do
        [{_, %Record{status: current_status} = rec}] ->
          cond do
            not from_ok?(from, current_status) ->
              {:error, :stale}

            not Status.can?(current_status, to_status) ->
              {:error, :illegal}

            true ->
              clean = Map.drop(attrs, [:id, :version, :seq])

              updated =
                rec
                |> Map.put(:status, to_status)
                |> Map.merge(clean)
                |> Map.update!(:version, &(&1 + 1))

              append_frame(wal, {:transition, run_id, to_status, clean})
              :ets.insert(table, {{:run, run_id}, updated})
              {:ok, updated}
          end

        [] ->
          {:error, :not_found}
      end
    end)
  end

  defp from_ok?(:any, status), do: not Status.terminal?(status)
  defp from_ok?(from, status) when is_list(from), do: status in from

  # ===================================================================
  # Signals
  # ===================================================================

  @impl Store
  def deliver_signal(%__MODULE__{index_table: table} = wal, run_id, name, payload) do
    seq = next_seq(table)
    id = "sig-#{seq}"
    sig = %Signal{id: id, run_id: run_id, name: name, payload: payload, seq: seq}
    append_frame(wal, {:signal, sig})
    :ets.insert(table, {{:signal, run_id, id}, sig})
    {:ok, sig}
  end

  @impl Store
  def pending_signal(%__MODULE__{index_table: table} = wal, run_id, name) do
    flush_before_read(wal)

    table
    |> sigs(run_id)
    |> Enum.find(&(&1.name == name and is_nil(&1.consumed_at)))
  end

  @impl Store
  def consume_signal(%__MODULE__{index_table: table} = wal, signal_id, now) do
    # Return :"$2" only: a 2-tuple return like {:"$1", :"$2"} compiles as a keyword list and
    # :ets.select raises ArgumentError (V5 P1: any consumed-signal frame bricked Wal.open/1).
    match_spec = [{{{:signal, :_, signal_id}, :"$2"}, [], [:"$2"]}]
    scope = {:signal, signal_id}

    with_row_lock(wal, scope, fn ->
      case :ets.select(table, match_spec) do
        [%Signal{consumed_at: nil, run_id: run_id} = sig] ->
          updated = %{sig | consumed_at: now}
          append_frame(wal, {:consume_signal, signal_id, now})
          :ets.insert(table, {{:signal, run_id, signal_id}, updated})
          {:ok, updated}

        _ ->
          :taken
      end
    end)
  end

  @impl Store
  def signals(%__MODULE__{index_table: table} = wal, run_id) do
    flush_before_read(wal)
    sigs(table, run_id)
  end

  # Atomic consume-once take in one locked transition (row lock {:run, id} serialises it with
  # record/transition, so checkpoint-adopt vs insert has no interleaving window): FIFO-find the
  # pending signal; `:none` when absent. A pending signal with a standing checkpoint for
  # step_key is the replay adopt (crash after commit): consume frame, signal consumed in the
  # index, waiter released, cp returned unchanged. A pending signal without one is the fresh
  # take: checkpoint frame + consume frame + waiter-release frame commit together before the
  # reply. STRICT law: no pending signal means `:none` for every step key — the ADOPT-consume
  # transition is pending-signal-gated (never adopt-regardless); engine crash recovery replays
  # from the standing checkpoint set, not from take_signal. A kill between frames replays via
  # the adopt path (crash-after-commit: checkpoint durable, signal re-delivered).
  @impl Store
  def take_signal(%__MODULE__{index_table: table} = wal, run_id, name, step_key, label, meta, now) do
    with_row_lock(wal, {:run, run_id}, fn ->
      sig = Enum.find(sigs(table, run_id), &(&1.name == name and is_nil(&1.consumed_at)))

      case sig do
        nil ->
          :none

        sig ->
          case :ets.lookup(table, {:checkpoint, run_id, step_key}) do
            [{_, cp}] ->
              append_frame(wal, {:consume_signal, sig.id, now})
              :ets.insert(table, {{:signal, run_id, sig.id}, %{sig | consumed_at: now}})
              :ets.delete(table, {:waiter, run_id, name})
              {:ok, cp}

            [] ->
              cp = %Checkpoint{
                run_id: run_id,
                step_key: step_key,
                label: label,
                name: Map.get(meta, :name),
                output: sig.payload,
                impl: Map.get(meta, :impl),
                args: Map.get(meta, :args),
                seq: next_seq(table)
              }

              append_frame(wal, {:checkpoint, cp})
              append_frame(wal, {:consume_signal, sig.id, now})
              append_frame(wal, {:release_waiter, run_id, name})
              :ets.insert(table, {{:checkpoint, run_id, step_key}, cp})
              :ets.insert(table, {{:signal, run_id, sig.id}, %{sig | consumed_at: now}})
              :ets.delete(table, {:waiter, run_id, name})
              {:ok, cp}
          end
      end
    end)
  end

  defp sigs(table, run_id) do
    match_spec = [{{{:signal, run_id, :_}, :"$1"}, [], [:"$1"]}]
    table |> :ets.select(match_spec) |> Enum.sort_by(& &1.seq)
  end

  # ===================================================================
  # Waiters
  # ===================================================================

  @impl Store
  def park(%__MODULE__{index_table: table} = wal, run_id, name, kind, deadline, opts) do
    # Callback contract: insert when absent; when present return the existing waiter
    # unchanged unless `overwrite: true`. Locked so concurrent parks adopt one deterministically.
    with_row_lock(wal, {:waiter, run_id, name}, fn ->
      case :ets.lookup(table, {:waiter, run_id, name}) do
        [{_, %Waiter{} = w}] ->
          if Keyword.get(opts, :overwrite, false) do
            {:ok, insert_waiter(wal, table, run_id, name, kind, deadline)}
          else
            {:ok, w}
          end

        _ ->
          {:ok, insert_waiter(wal, table, run_id, name, kind, deadline)}
      end
    end)
  end

  defp insert_waiter(wal, table, run_id, name, kind, deadline) do
    waiter = %Waiter{run_id: run_id, name: name, kind: kind, deadline: deadline}
    append_frame(wal, {:waiter, waiter})
    :ets.insert(table, {{:waiter, run_id, name}, waiter})
    waiter
  end

  @impl Store
  def get_waiter(%__MODULE__{index_table: table} = wal, run_id, name) do
    flush_before_read(wal)

    case :ets.lookup(table, {:waiter, run_id, name}) do
      [{_, waiter}] -> waiter
      [] -> nil
    end
  end

  @impl Store
  def waiters(%__MODULE__{index_table: table} = wal, run_id) do
    flush_before_read(wal)
    match_spec = [{{{:waiter, run_id, :_}, :"$1"}, [], [:"$1"]}]
    table |> :ets.select(match_spec) |> Enum.sort_by(& &1.name)
  end

  @impl Store
  def release(%__MODULE__{index_table: table} = wal, run_id, name) do
    with_row_lock(wal, {:waiter, run_id, name}, fn ->
      append_frame(wal, {:release_waiter, run_id, name})
      :ets.delete(table, {:waiter, run_id, name})
      :ok
    end)
  end

  @impl Store
  def release_all(%__MODULE__{index_table: table} = wal, run_id) do
    with_row_lock(wal, {:waiter_scope, run_id}, fn ->
      match_spec = [{{{:waiter, run_id, :_}, :_}, [], [true]}]
      :ets.select_delete(table, match_spec)
      append_frame(wal, {:release_all_waiters, run_id})
      :ok
    end)
  end

  # ===================================================================
  # Internal Binary Framing & Hydration
  # ===================================================================

  # Ack-class append: the writer replies only after the frame's batch is written to the
  # open device (crash window: none for this caller). A dead writer (store killed) exits
  # the caller - a loud failure, never a silent loss.
  defp append_frame(%__MODULE__{writer: writer}, term) do
    payload = :erlang.term_to_binary(term)
    len = byte_size(payload)
    crc = :erlang.crc32(payload)
    frame = <<len::unsigned-integer-32, crc::unsigned-integer-32, payload::binary>>
    Writer.append_ack(writer, frame)
    :ok
  end

  # Returns :ok or {:error, {:wal_integrity, detail}}. A torn tail is truncated at the last
  # good frame boundary (crash recovery); a mid-stream CRC/decoding failure is a typed error.
  defp hydrate_index(%__MODULE__{path: path} = wal) do
    case File.read(path) do
      {:ok, binary} -> parse_frames(binary, wal, 0)
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:io_error, reason}}
    end
  end

  defp parse_frames(<<>>, _wal, _offset), do: :ok

  defp parse_frames(tail, wal, offset) when byte_size(tail) < 8 do
    truncate_tail(wal, offset)
  end

  defp parse_frames(
         <<len::unsigned-integer-32, crc::unsigned-integer-32, rest::binary>>,
         wal,
         offset
       ) do
    if len > byte_size(rest) do
      truncate_tail(wal, offset)
    else
      <<payload::binary-size(^len), tail::binary>> = rest

      if :erlang.crc32(payload) == crc do
        case decode_frame(payload) do
          {:ok, frame} ->
            apply_frame_to_index(frame, wal.index_table)
            parse_frames(tail, wal, offset + 8 + len)

          {:error, _} = err ->
            err
        end
      else
        {:error, {:wal_integrity, {:crc_mismatch, offset}}}
      end
    end
  end

  defp decode_frame(payload) do
    try do
      {:ok, :erlang.binary_to_term(payload, [:safe])}
    rescue
      _ -> {:error, {:wal_integrity, :undecodable_frame}}
    end
  end

  defp truncate_tail(%__MODULE__{path: path}, offset) do
    # No File.truncate/2 in Elixir: rewrite the kept prefix (WAL files here are small).
    <<keep::binary-size(^offset), _dropped::binary>> = File.read!(path)
    File.write!(path, keep)
    :ok
  end

  # Re-derives the volatile {:wal_seq} counter row from the maximum seq present in the
  # replayed index, so ids/ordering stay monotonic across reopen.
  defp hydrate_seq(%__MODULE__{index_table: table}) do
    max =
      table
      |> :ets.tab2list()
      |> Enum.reduce(0, fn
        {_, %Record{seq: s}}, acc when is_integer(s) -> max(acc, s)
        {_, %Checkpoint{seq: s}}, acc when is_integer(s) -> max(acc, s)
        {_, %Signal{seq: s}}, acc when is_integer(s) -> max(acc, s)
        _, acc -> acc
      end)

    :ets.insert(table, {{:wal_seq}, max})
    :ok
  end

  defp apply_frame_to_index({:start_run, record}, table),
    do: :ets.insert(table, {{:run, record.id}, record})

  defp apply_frame_to_index({:claim, id, claimer, exp, now}, table) do
    case :ets.lookup(table, {:run, id}) do
      [{_, rec}] ->
        :ets.insert(
          table,
          {{:run, id},
           %{
             rec
             | lease_until: DateTime.from_unix!(exp, :millisecond),
               claimed_by: claimer,
               claimed_at: now
           }}
        )

      [] ->
        :ok
    end
  end

  defp apply_frame_to_index({:release_claim, id}, table) do
    case :ets.lookup(table, {:run, id}) do
      [{_, rec}] ->
        :ets.insert(
          table,
          {{:run, id}, %{rec | lease_until: nil, lease_ms: nil, claimed_by: nil, claimed_at: nil}}
        )

      [] ->
        :ok
    end
  end

  defp apply_frame_to_index({:renew_claim, id, _claimer, exp}, table) do
    case :ets.lookup(table, {:run, id}) do
      [{_, rec}] ->
        :ets.insert(
          table,
          {{:run, id}, %{rec | lease_until: DateTime.from_unix!(exp, :millisecond)}}
        )

      [] ->
        :ok
    end
  end

  defp apply_frame_to_index({:checkpoint, cp}, table),
    do: :ets.insert(table, {{:checkpoint, cp.run_id, cp.step_key}, cp})

  defp apply_frame_to_index({:checkpoint_undone, run_id, step_key, now}, table) do
    case :ets.lookup(table, {:checkpoint, run_id, step_key}) do
      [{_, cp}] ->
        :ets.insert(table, {{:checkpoint, run_id, step_key}, %{cp | undone_at: now}})

      [] ->
        :ok
    end
  end

  defp apply_frame_to_index({:transition, run_id, to_status, attrs}, table) do
    case :ets.lookup(table, {:run, run_id}) do
      [{_, rec}] ->
        updated =
          rec
          |> Map.put(:status, to_status)
          |> Map.merge(Map.drop(attrs, [:id, :version, :seq]))
          |> Map.update!(:version, &(&1 + 1))

        :ets.insert(table, {{:run, run_id}, updated})

      [] ->
        :ok
    end
  end

  defp apply_frame_to_index({:signal, sig}, table),
    do: :ets.insert(table, {{:signal, sig.run_id, sig.id}, sig})

  defp apply_frame_to_index({:consume_signal, signal_id, now}, table) do
    match_spec = [{{{:signal, :_, signal_id}, :"$2"}, [], [:"$2"]}]

    case :ets.select(table, match_spec) do
      [%Signal{consumed_at: nil, run_id: run_id} = sig] ->
        :ets.insert(table, {{:signal, run_id, signal_id}, %{sig | consumed_at: now}})

      _ ->
        :ok
    end
  end

  defp apply_frame_to_index({:waiter, waiter}, table),
    do: :ets.insert(table, {{:waiter, waiter.run_id, waiter.name}, waiter})

  defp apply_frame_to_index({:release_waiter, run_id, name}, table),
    do: :ets.delete(table, {:waiter, run_id, name})

  defp apply_frame_to_index({:release_all_waiters, run_id}, table) do
    match_spec = [{{{:waiter, run_id, :_}, :_}, [], [true]}]
    :ets.select_delete(table, match_spec)
  end

  defp apply_frame_to_index(_other, _table), do: :ok

  # ===================================================================
  # Batched append writer (Z6)
  # ===================================================================

  defmodule Writer do
    use GenServer

    @moduledoc """
    Per-store append writer: one open file device, batched writes, caller-acked
    durability. See the parent module's "Batched append writer (Z6)" section.
    """

    @batch_frames 32
    @flush_ms 25

    defstruct [:fd, :buf, :buf_count, :pending, :timer]

    @type t :: %__MODULE__{
            fd: :file.io_device(),
            buf: [binary()],
            buf_count: non_neg_integer(),
            pending: [GenServer.from()],
            timer: reference() | nil
          }

    # -- API ---------------------------------------------------------

    def start_link(path) do
      GenServer.start_link(__MODULE__, path)
    end

    # Ack-class append: blocks the caller until its frame's batch hits the device.
    def append_ack(pid, frame) do
      GenServer.call(pid, {:ack, frame}, :infinity)
    end

    # Fire-and-forget append: buffered, flushed at @batch_frames / @flush_ms / read.
    # No store callback uses this path today (kept for future non-ack callers).
    def append_async(pid, frame) do
      GenServer.cast(pid, {:nack, frame})
    end

    # Durability-before-read / close: drain the buffer now.
    def flush(pid) do
      GenServer.call(pid, :flush, :infinity)
    end

    def flush_and_stop(pid) do
      GenServer.call(pid, :flush_and_stop, :infinity)
    end

    # -- Server ------------------------------------------------------

    @impl GenServer
    def init(path) do
      fd = File.open!(path, [:raw, :binary, :append])
      {:ok, %__MODULE__{fd: fd, buf: [], buf_count: 0, pending: [], timer: nil}}
    end

    @impl GenServer
    def handle_call({:ack, frame}, from, st) do
      st = st |> push(frame, from) |> drain_mailbox()
      # Ack-class law: flush before ANY pending ack replies (coalesced frames ride along).
      # flush_buffer/1 replies to all pending callers via GenServer.reply/2; returning
      # {:noreply, ...} prevents sending a duplicate reply to `from`.
      {:noreply, flush_buffer(st)}
    end

    def handle_call(:flush, _from, st) do
      {:reply, :ok, flush_buffer(st)}
    end

    def handle_call(:flush_and_stop, _from, st) do
      flush_buffer(st)
      {:stop, :normal, :ok, st}
    end

    @impl GenServer
    def handle_cast({:nack, frame}, st) do
      st = push(st, frame, nil)

      if st.buf_count >= @batch_frames do
        {:noreply, flush_buffer(st)}
      else
        {:noreply, arm_timer(st)}
      end
    end

    @impl GenServer
    def handle_info(:flush_deadline, st) do
      {:noreply, flush_buffer(%{st | timer: nil})}
    end

    # -- Internals ---------------------------------------------------

    defp push(st, frame, from) do
      %{
        st
        | buf: [frame | st.buf],
          buf_count: st.buf_count + 1,
          pending: if(from, do: [from | st.pending], else: st.pending)
      }
    end

    # Coalescing: frames already queued behind the current message join this batch.
    # Raw protocol tuples (:"$gen_call"/:"$gen_cast") so drain sees both classes.
    defp drain_mailbox(st) do
      receive do
        {:"$gen_call", from2, {:ack, frame}} -> drain_mailbox(push(st, frame, from2))
        {:"$gen_cast", {:nack, frame}} -> drain_mailbox(push(st, frame, nil))
      after
        0 -> st
      end
    end

    # ONE open+append per batch: a single iodata write to the persistent device, then
    # reply every acked caller in the batch. An acked frame is post-write, always.
    defp flush_buffer(%{buf_count: 0} = st), do: %{st | timer: nil}

    defp flush_buffer(st) do
      if st.timer, do: Process.cancel_timer(st.timer)
      iodata = Enum.reverse(st.buf)
      :ok = :file.write(st.fd, iodata)

      Enum.each(st.pending, &GenServer.reply(&1, :ok))
      %{st | buf: [], buf_count: 0, pending: [], timer: nil}
    end

    defp arm_timer(%{timer: nil} = st) do
      %{st | timer: Process.send_after(self(), :flush_deadline, @flush_ms)}
    end

    defp arm_timer(st), do: st
  end
end

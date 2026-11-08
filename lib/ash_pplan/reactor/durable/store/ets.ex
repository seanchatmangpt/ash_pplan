defmodule AshPPlan.Reactor.Durable.Store.Ets do
  @moduledoc """
  In-memory `AshPPlan.Reactor.Durable.Store` backed by private ETS tables owned by one GenServer.

  Every operation is a `GenServer.call`, so the server's mailbox serialises all reads and writes:
  claim, transition, consume_signal, claim_undo and record (insert-or-adopt) are linearizable
  compare-and-set operations. Design derived from mbuhot/magma (MIT per its mix.exs).
  """
  use GenServer

  @behaviour AshPPlan.Reactor.Durable.Store

  alias AshPPlan.Reactor.Durable.{Checkpoint, Clock, Record, Signal, Status, Waiter}

  @protected_keys [:id, :version, :seq]

  # Volatile undo claims expire on this lease (measured from claim_undo's `now`), so a rollback
  # process that dies without releasing can never wedge the checkpoint out of `standing` forever.
  @undo_claim_lease_ms 30_000

  # -- client ---------------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    gen_opts = if n = opts[:name], do: [name: n], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @impl AshPPlan.Reactor.Durable.Store
  def start_run(s, attrs), do: call(s, {:start_run, attrs})
  @impl AshPPlan.Reactor.Durable.Store
  def get_run(s, id), do: call(s, {:get_run, id})
  @impl AshPPlan.Reactor.Durable.Store
  def list_runs(s), do: call(s, :list_runs)
  @impl AshPPlan.Reactor.Durable.Store
  def transition(s, id, from, to, attrs), do: call(s, {:transition, id, from, to, attrs})
  @impl AshPPlan.Reactor.Durable.Store
  def claim(s, id, claimer, lease_ms, now), do: call(s, {:claim, id, claimer, lease_ms, now})
  @impl AshPPlan.Reactor.Durable.Store
  def release_claim(s, id, claimer), do: call(s, {:release_claim, id, claimer})
  @impl AshPPlan.Reactor.Durable.Store
  def renew_claim(s, id, claimer, lease_ms), do: call(s, {:renew_claim, id, claimer, lease_ms})
  @impl AshPPlan.Reactor.Durable.Store
  def checkpoints(s, id), do: call(s, {:checkpoints, id})
  @impl AshPPlan.Reactor.Durable.Store
  def standing(s, id), do: call(s, {:standing, id})
  @impl AshPPlan.Reactor.Durable.Store
  def snapshot(s, id), do: call(s, {:snapshot, id})
  @impl AshPPlan.Reactor.Durable.Store
  def record(s, id, key, label, output, meta),
    do: call(s, {:record, id, key, label, output, meta})

  @impl AshPPlan.Reactor.Durable.Store
  def claim_undo(s, id, key, now), do: call(s, {:claim_undo, id, key, now})
  @impl AshPPlan.Reactor.Durable.Store
  def mark_undone(s, id, key, now), do: call(s, {:mark_undone, id, key, now})
  @impl AshPPlan.Reactor.Durable.Store
  def release_undo(s, id, key), do: call(s, {:release_undo, id, key})
  @impl AshPPlan.Reactor.Durable.Store
  def take_signal(s, id, name, step_key, label, meta, now),
    do: call(s, {:take_signal, id, name, step_key, label, meta, now})

  @impl AshPPlan.Reactor.Durable.Store
  def deliver_signal(s, id, name, payload), do: call(s, {:deliver_signal, id, name, payload})
  @impl AshPPlan.Reactor.Durable.Store
  def pending_signal(s, id, name), do: call(s, {:pending_signal, id, name})
  @impl AshPPlan.Reactor.Durable.Store
  def consume_signal(s, sid, now), do: call(s, {:consume_signal, sid, now})
  @impl AshPPlan.Reactor.Durable.Store
  def park(s, id, name, kind, deadline, opts \\ []),
    do: call(s, {:park, id, name, kind, deadline, opts})

  @impl AshPPlan.Reactor.Durable.Store
  def get_waiter(s, id, name), do: call(s, {:get_waiter, id, name})
  @impl AshPPlan.Reactor.Durable.Store
  def waiters(s, id), do: call(s, {:waiters, id})
  @impl AshPPlan.Reactor.Durable.Store
  def release(s, id, name), do: call(s, {:release, id, name})
  @impl AshPPlan.Reactor.Durable.Store
  def release_all(s, id), do: call(s, {:release_all, id})
  @impl AshPPlan.Reactor.Durable.Store
  def signals(s, id), do: call(s, {:signals, id})

  defp call(s, msg), do: GenServer.call(s, msg, :infinity)

  # -- server ---------------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    {:ok,
     %{
       runs: :ets.new(:runs, [:set, :private]),
       cps: :ets.new(:cps, [:set, :private]),
       # ordered per-run view of checkpoints: {run_id, seq} -> cp, so standing/checkpoints are
       # an ordered range scan (O(k log n)) instead of a full-table tab2list + sort per call
       cps_seq: :ets.new(:cps_seq, [:ordered_set, :private]),
       signals: :ets.new(:signals, [:set, :private]),
       waiters: :ets.new(:waiters, [:set, :private]),
       # volatile undo claims: {run_id, step_key} => expires_at (server state, never persisted)
       undo_claims: %{},
       seq: 0
     }}
  end

  @impl GenServer
  def handle_call(msg, _from, st) do
    {reply, st} = do_call(msg, st)
    {:reply, reply, st}
  end

  defp next(st), do: {st.seq + 1, %{st | seq: st.seq + 1}}

  defp do_call({:start_run, attrs}, st) do
    id = Map.fetch!(attrs, :id)

    case :ets.lookup(st.runs, id) do
      [_] ->
        {{:error, :exists}, st}

      [] ->
        {seq, st} = next(st)
        {parent_id, parent_signal} = parent(Map.get(attrs, :parent))

        base =
          attrs
          |> Map.drop([:parent | @protected_keys])
          |> Map.take(Map.keys(Map.from_struct(%Record{id: nil})))

        rec =
          struct!(Record, Map.merge(base, %{id: id, seq: seq, version: 1}))
          |> Map.merge(%{parent_id: parent_id, parent_signal: parent_signal})

        :ets.insert(st.runs, {id, rec})
        {{:ok, rec}, st}
    end
  end

  defp do_call({:get_run, id}, st), do: {fetch_run(st, id), st}

  defp do_call(:list_runs, st) do
    runs = st.runs |> :ets.tab2list() |> Enum.map(&elem(&1, 1)) |> Enum.sort_by(& &1.seq)
    {runs, st}
  end

  defp do_call({:transition, id, from, to, attrs}, st) do
    case fetch_run(st, id) do
      nil ->
        {{:error, :not_found}, st}

      rec ->
        cond do
          not from_ok?(from, rec.status) -> {{:error, :stale}, st}
          not Status.can?(rec.status, to) -> {{:error, :illegal}, st}
          true -> {{:ok, put_run(st, rec, Map.put(attrs, :status, to))}, st}
        end
    end
  end

  defp do_call({:claim, id, claimer, lease_ms, now}, st) do
    case fetch_run(st, id) do
      nil ->
        {:taken, st}

      rec ->
        if claimable?(rec, claimer, now) do
          new =
            put_run(st, rec, %{
              claimed_by: claimer,
              claimed_at: now,
              lease_ms: lease_ms,
              lease_until: Clock.add(now, lease_ms)
            })

          {{:ok, new}, st}
        else
          {:taken, st}
        end
    end
  end

  defp do_call({:renew_claim, id, claimer, lease_ms}, st) do
    case fetch_run(st, id) do
      %Record{claimed_by: ^claimer, claimed_at: at} = rec
      when not is_nil(claimer) and not is_nil(at) ->
        now = Clock.now()
        new = put_run(st, rec, %{lease_ms: lease_ms, lease_until: Clock.add(now, lease_ms)})
        {{:ok, new}, st}

      _ ->
        {:taken, st}
    end
  end

  defp do_call({:release_claim, id, claimer}, st) do
    case fetch_run(st, id) do
      %Record{claimed_by: ^claimer} = rec when not is_nil(claimer) ->
        put_run(st, rec, %{claimed_by: nil, claimed_at: nil, lease_ms: nil, lease_until: nil})
        {:ok, st}

      _ ->
        {:ok, st}
    end
  end

  defp do_call({:checkpoints, id}, st),
    do: {Map.new(cps_ordered(st, id), &{&1.step_key, &1}), st}

  defp do_call({:standing, id}, st), do: {standing_rows(st, id), st}

  # one consistent read inside a single GenServer message: the run plus its standing
  # checkpoints already in ascending seq (the ordered-set range scan yields seq order, so
  # the caller needs no sort). Seq-capped: it is the standing as of this store's seq now.
  defp do_call({:snapshot, id}, st) do
    case fetch_run(st, id) do
      nil -> {nil, st}
      run -> {{run, standing_rows(st, id)}, st}
    end
  end

  defp do_call({:record, id, key, label, output, meta}, st) do
    case :ets.lookup(st.cps, {id, key}) do
      [{_, cp}] ->
        {{:ok, cp}, st}

      [] ->
        case fetch_run(st, id) do
          %Record{status: s} ->
            if Status.terminal?(s),
              do: {{:error, :terminal}, st},
              else: insert_cp(st, id, key, label, output, meta)

          nil ->
            insert_cp(st, id, key, label, output, meta)
        end
    end
  end

  # A live (unexpired) volatile claim makes a re-claim :taken; an expired one is taken over.
  # The checkpoint's `undone_at` is NOT written here - only `mark_undone/4` writes it, after
  # the undo effect succeeded, so a crash in between leaves the undo to re-run.
  defp do_call({:claim_undo, id, key, now}, st) do
    case :ets.lookup(st.cps, {id, key}) do
      [{_k, %Checkpoint{undone_at: nil} = cp}] ->
        if undo_claim_live?(st, id, key, now) do
          {:taken, st}
        else
          expires = Clock.add(now, @undo_claim_lease_ms)
          {{:ok, cp}, %{st | undo_claims: Map.put(st.undo_claims, {id, key}, expires)}}
        end

      _ ->
        {:taken, st}
    end
  end

  # Guarded idempotent mark: first mark writes `undone_at`; a re-mark is a no-op answer.
  defp do_call({:mark_undone, id, key, now}, st) do
    case :ets.lookup(st.cps, {id, key}) do
      [{k, %Checkpoint{undone_at: nil} = cp}] ->
        cp = %{cp | undone_at: now}
        :ets.insert(st.cps, {k, cp})
        :ets.insert(st.cps_seq, {{id, cp.seq}, cp})
        {{:ok, cp}, %{st | undo_claims: Map.delete(st.undo_claims, {id, key})}}

      [{_k, cp}] ->
        {{:ok, cp}, st}

      [] ->
        {{:error, :not_found}, st}
    end
  end

  defp do_call({:release_undo, id, key}, st) do
    {:ok, %{st | undo_claims: Map.delete(st.undo_claims, {id, key})}}
  end

  # Atomic consume-once take in one message: FIFO-find the pending signal; `:none` when absent.
  # A pending signal with a standing checkpoint for step_key is the replay adopt (crash after
  # commit): consume the re-delivered signal, release the waiter, return the standing cp. A
  # pending signal without one is the fresh take: insert cp (output = payload), consume the
  # signal and release the waiter - committed together in one linearizable transition.
  # STRICT law: no pending signal means `:none` for every step key — the ADOPT-consume
  # transition is pending-signal-gated (never adopt-regardless); engine crash recovery replays
  # from the standing checkpoint set, not from take_signal.
  defp do_call({:take_signal, id, name, key, label, meta, now}, st) do
    case Enum.find(sigs(st, id), &(&1.name == name and is_nil(&1.consumed_at))) do
      nil ->
        {:none, st}

      sig ->
        case :ets.lookup(st.cps, {id, key}) do
          [{_k, cp}] ->
            :ets.insert(st.signals, {sig.id, %{sig | consumed_at: now}})
            :ets.delete(st.waiters, {id, name})
            {{:ok, cp}, st}

          [] ->
            {{:ok, cp}, st} = insert_cp(st, id, key, label, sig.payload, meta)
            :ets.insert(st.signals, {sig.id, %{sig | consumed_at: now}})
            :ets.delete(st.waiters, {id, name})
            {{:ok, cp}, st}
        end
    end
  end

  defp do_call({:deliver_signal, id, name, payload}, st) do
    {seq, st} = next(st)
    sig = %Signal{id: seq, run_id: id, name: name, payload: payload, seq: seq}
    :ets.insert(st.signals, {seq, sig})
    {{:ok, sig}, st}
  end

  defp do_call({:pending_signal, id, name}, st) do
    sig =
      st
      |> sigs(id)
      |> Enum.find(&(&1.name == name and is_nil(&1.consumed_at)))

    {sig, st}
  end

  defp do_call({:consume_signal, sid, now}, st) do
    case :ets.lookup(st.signals, sid) do
      [{k, %Signal{consumed_at: nil} = sig}] ->
        sig = %{sig | consumed_at: now}
        :ets.insert(st.signals, {k, sig})
        {{:ok, sig}, st}

      _ ->
        {:taken, st}
    end
  end

  defp do_call({:park, id, name, kind, deadline, opts}, st) do
    key = {id, name}

    case :ets.lookup(st.waiters, key) do
      [{_, w}] when w != nil ->
        if Keyword.get(opts, :overwrite, false) do
          {{:ok, insert_waiter(st, id, name, kind, deadline)}, st}
        else
          {{:ok, w}, st}
        end

      _ ->
        {{:ok, insert_waiter(st, id, name, kind, deadline)}, st}
    end
  end

  defp do_call({:get_waiter, id, name}, st) do
    case :ets.lookup(st.waiters, {id, name}) do
      [{_, w}] -> {w, st}
      [] -> {nil, st}
    end
  end

  defp do_call({:waiters, id}, st) do
    ws = for {{^id, _}, w} <- :ets.tab2list(st.waiters), do: w
    {Enum.sort_by(ws, & &1.name), st}
  end

  defp do_call({:release, id, name}, st) do
    :ets.delete(st.waiters, {id, name})
    {:ok, st}
  end

  defp do_call({:release_all, id}, st) do
    :ets.match_delete(st.waiters, {{id, :_}, :_})
    {:ok, st}
  end

  defp do_call({:signals, id}, st), do: {sigs(st, id), st}

  # -- helpers --------------------------------------------------------------------------------

  defp parent({pid, sig}), do: {pid, sig}
  defp parent(nil), do: {nil, nil}

  defp insert_cp(st, id, key, label, output, meta) do
    {seq, st} = next(st)

    cp = %Checkpoint{
      run_id: id,
      step_key: key,
      label: label,
      name: Map.get(meta, :name),
      output: output,
      impl: Map.get(meta, :impl),
      args: Map.get(meta, :args),
      seq: seq
    }

    :ets.insert(st.cps, {{id, key}, cp})
    :ets.insert(st.cps_seq, {{id, seq}, cp})
    {{:ok, cp}, st}
  end

  defp fetch_run(st, id) do
    case :ets.lookup(st.runs, id) do
      [{_, r}] -> r
      [] -> nil
    end
  end

  defp put_run(st, rec, attrs) do
    new =
      rec
      |> Map.merge(Map.drop(attrs, @protected_keys))
      |> Map.update!(:version, &(&1 + 1))

    :ets.insert(st.runs, {rec.id, new})
    new
  end

  defp from_ok?(:any, status), do: not Status.terminal?(status)
  # Enum.member?/2 not `in`: `in` with a runtime right side expands to a compiler-internal
  # (Enum.__in__/2 on some Elixir builds) — a beam compiled by a mismatched Elixir crashed the
  # GenServer here (UndefinedFunctionError mid-transition), and every later call got :noproc.
  defp from_ok?(from, status) when is_list(from), do: Enum.member?(from, status)

  # The lease lives on the record: claimed + nil `lease_until` fails CLOSED (never claimable by
  # another claimer), so a lost lease write can never be silently claimed over.
  defp claimable?(%Record{claimed_at: nil}, _claimer, _now), do: true

  defp claimable?(%Record{claimed_by: by}, claimer, _now)
       when not is_nil(claimer) and by == claimer,
       do: true

  defp claimable?(%Record{lease_until: nil}, _claimer, _now), do: false

  defp claimable?(%Record{lease_until: until}, _claimer, now),
    do: DateTime.compare(now, until) != :lt

  defp undo_claim_live?(st, id, key, now) do
    case Map.get(st.undo_claims, {id, key}) do
      nil -> false
      expires -> DateTime.compare(now, expires) == :lt
    end
  end

  # ordered range scan over the per-run seq index: {run_id, seq} keys sort ascending by seq
  # for one run, so walking :ets.next from the run's floor key yields seq-sorted checkpoints
  # with no sort and no full-table scan. The floor key {id, 0} never collides (seqs start at 1).
  defp cps_ordered(st, id) do
    scan_from(st, :ets.next(st.cps_seq, {id, 0}), id, [])
  end

  defp scan_from(st, {key_id, _} = key, id, acc) when key_id == id do
    [{_key, cp}] = :ets.lookup(st.cps_seq, key)
    scan_from(st, :ets.next(st.cps_seq, key), id, [cp | acc])
  end

  defp scan_from(_st, _other, _id, acc), do: Enum.reverse(acc)

  defp standing_rows(st, id),
    do: Enum.filter(cps_ordered(st, id), &is_nil(&1.undone_at))

  defp sigs(st, id) do
    for({_, %Signal{run_id: ^id} = s} <- :ets.tab2list(st.signals), do: s)
    |> Enum.sort_by(& &1.seq)
  end

  defp insert_waiter(st, id, name, kind, deadline) do
    w = %Waiter{run_id: id, name: name, kind: kind, deadline: deadline}
    :ets.insert(st.waiters, {{id, name}, w})
    w
  end
end

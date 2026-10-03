defmodule AshPPlan.Reactor.Durable.Store.Dets do
  @moduledoc """
  Persistent `AshPPlan.Reactor.Durable.Store` backed by one DETS file owned by one GenServer.

  The server's mailbox serialises every call exactly as `Store.Ets` does, so claim, transition,
  consume_signal, claim_undo and record (insert-or-adopt) stay linearizable compare-and-set
  operations. Every mutating call is followed by `:dets.sync/1`, so a stopped, crashed or killed
  store process loses nothing a caller was told succeeded: start a new store on the same `:path`
  and the runs, standing checkpoints, signals, waiters, claim leases and sequence counter are
  intact.

  ## Options

    * `:path` (required) - DETS file path (binary or charlist).
    * `:name` - optional registered name of the GenServer.

  A node-local path lock refuses a second concurrent open of the same file with
  `{:error, {:path_in_use, path}}` - DETS itself permits double opens (with repair churn), which
  would let two servers interleave writes. A dead owner's lock is taken over, so a killed store
  reopens cleanly.

  Conformance is proven by the generated `AshPPlan.Test.StoreConformance` suite. Design derived
  from mbuhot/magma (MIT per its mix.exs).
  """
  use GenServer

  @behaviour AshPPlan.Reactor.Durable.Store

  alias AshPPlan.Reactor.Durable.{Checkpoint, Record, Signal, Status, Waiter}

  @protected_keys [:id, :version, :seq]

  # -- client ---------------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    Keyword.fetch!(opts, :path)
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
  def checkpoints(s, id), do: call(s, {:checkpoints, id})
  @impl AshPPlan.Reactor.Durable.Store
  def standing(s, id), do: call(s, {:standing, id})
  @impl AshPPlan.Reactor.Durable.Store
  def record(s, id, key, label, output, meta),
    do: call(s, {:record, id, key, label, output, meta})

  @impl AshPPlan.Reactor.Durable.Store
  def claim_undo(s, id, key, now), do: call(s, {:claim_undo, id, key, now})
  @impl AshPPlan.Reactor.Durable.Store
  def release_undo(s, id, key), do: call(s, {:release_undo, id, key})
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

  @lock_table AshPPlan.Reactor.Durable.Store.Dets.PathLock

  @impl GenServer
  def init(opts) do
    path = opts |> Keyword.fetch!(:path) |> to_string() |> Path.expand() |> to_charlist()
    tab = {__MODULE__, make_ref()}

    case claim_path_lock(path) do
      :ok ->
        case :dets.open_file(tab, file: path, type: :set, access: :read_write) do
          {:ok, ^tab} ->
            # trap_exit only after a successful open: with the flag set during init, a failed
            # start_link also delivers {:EXIT, pid, reason} to a non-trapping caller and kills it
            Process.flag(:trap_exit, true)
            seq = lookup(tab, :seq, 0)
            {:ok, %{tab: tab, seq: seq, path: path}}

          {:error, reason} ->
            release_path_lock(path)
            {:stop, {:dets_open_failed, reason}}
        end

      {:error, {:path_in_use, _} = reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def terminate(_reason, %{tab: tab, path: path}) do
    :dets.sync(tab)
    :dets.close(tab)
    release_path_lock(path)
    :ok
  rescue
    _ -> :ok
  end

  @impl GenServer
  def handle_call(msg, _from, st) do
    {reply, st} = do_call(msg, st)
    :dets.sync(st.tab)
    {:reply, reply, st}
  end

  defp next(st) do
    seq = st.seq + 1
    :ok = :dets.insert(st.tab, {:seq, seq})
    {seq, %{st | seq: seq}}
  end

  defp do_call({:start_run, attrs}, st) do
    id = Map.fetch!(attrs, :id)

    case fetch_run(st, id) do
      %Record{} ->
        {{:error, :exists}, st}

      nil ->
        {seq, st} = next(st)
        {parent_id, parent_signal} = parent(Map.get(attrs, :parent))

        base =
          attrs
          |> Map.drop([:parent | @protected_keys])
          |> Map.take(Map.keys(Map.from_struct(%Record{id: nil})))

        rec =
          struct!(Record, Map.merge(base, %{id: id, seq: seq, version: 1}))
          |> Map.merge(%{parent_id: parent_id, parent_signal: parent_signal})

        :ok = :dets.insert(st.tab, {{:run, id}, rec})
        {{:ok, rec}, st}
    end
  end

  defp do_call({:get_run, id}, st), do: {fetch_run(st, id), st}

  defp do_call(:list_runs, st) do
    runs =
      st.tab
      |> :dets.select([{{{:run, :_}, :"$1"}, [], [:"$1"]}])
      |> Enum.sort_by(& &1.seq)

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
        if claimable?(rec, claimer, lookup(st.tab, {:lease, id}, nil), now) do
          new = put_run(st, rec, %{claimed_by: claimer, claimed_at: now})
          :ok = :dets.insert(st.tab, {{:lease, id}, lease_ms})
          {{:ok, new}, st}
        else
          {:taken, st}
        end
    end
  end

  defp do_call({:release_claim, id, claimer}, st) do
    case fetch_run(st, id) do
      %Record{claimed_by: ^claimer} = rec when not is_nil(claimer) ->
        put_run(st, rec, %{claimed_by: nil, claimed_at: nil})
        :ok = :dets.delete(st.tab, {:lease, id})
        {:ok, st}

      _ ->
        {:ok, st}
    end
  end

  defp do_call({:checkpoints, id}, st),
    do: {Map.new(cps(st, id), &{&1.step_key, &1}), st}

  defp do_call({:standing, id}, st),
    do: {Enum.filter(cps(st, id), &is_nil(&1.undone_at)), st}

  defp do_call({:record, id, key, label, output, meta}, st) do
    case lookup(st.tab, {:cp, id, key}, nil) do
      %Checkpoint{} = cp ->
        {{:ok, cp}, st}

      nil ->
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

  defp do_call({:claim_undo, id, key, now}, st) do
    case lookup(st.tab, {:cp, id, key}, nil) do
      %Checkpoint{undone_at: nil} = cp ->
        cp = %{cp | undone_at: now}
        :ok = :dets.insert(st.tab, {{:cp, id, key}, cp})
        {{:ok, cp}, st}

      _ ->
        {:taken, st}
    end
  end

  defp do_call({:release_undo, id, key}, st) do
    case lookup(st.tab, {:cp, id, key}, nil) do
      %Checkpoint{} = cp -> :ok = :dets.insert(st.tab, {{:cp, id, key}, %{cp | undone_at: nil}})
      nil -> :ok
    end

    {:ok, st}
  end

  defp do_call({:deliver_signal, id, name, payload}, st) do
    {seq, st} = next(st)
    sig = %Signal{id: seq, run_id: id, name: name, payload: payload, seq: seq}
    :ok = :dets.insert(st.tab, {{:sig, seq}, sig})
    {{:ok, sig}, st}
  end

  defp do_call({:pending_signal, id, name}, st) do
    {st |> sigs(id) |> Enum.find(&(&1.name == name and is_nil(&1.consumed_at))), st}
  end

  defp do_call({:consume_signal, sid, now}, st) do
    case lookup(st.tab, {:sig, sid}, nil) do
      %Signal{consumed_at: nil} = sig ->
        sig = %{sig | consumed_at: now}
        :ok = :dets.insert(st.tab, {{:sig, sid}, sig})
        {{:ok, sig}, st}

      _ ->
        {:taken, st}
    end
  end

  defp do_call({:park, id, name, kind, deadline, opts}, st) do
    case lookup(st.tab, {:waiter, id, name}, nil) do
      %Waiter{} = w ->
        if Keyword.get(opts, :overwrite, false),
          do: {{:ok, insert_waiter(st, id, name, kind, deadline)}, st},
          else: {{:ok, w}, st}

      nil ->
        {{:ok, insert_waiter(st, id, name, kind, deadline)}, st}
    end
  end

  defp do_call({:get_waiter, id, name}, st),
    do: {lookup(st.tab, {:waiter, id, name}, nil), st}

  defp do_call({:waiters, id}, st) do
    ws = :dets.select(st.tab, [{{{:waiter, id, :_}, :"$1"}, [], [:"$1"]}])
    {Enum.sort_by(ws, & &1.name), st}
  end

  defp do_call({:release, id, name}, st) do
    :ok = :dets.delete(st.tab, {:waiter, id, name})
    {:ok, st}
  end

  defp do_call({:release_all, id}, st) do
    :dets.match_delete(st.tab, {{:waiter, id, :_}, :_})
    {:ok, st}
  end

  defp do_call({:signals, id}, st), do: {sigs(st, id), st}

  # -- helpers --------------------------------------------------------------------------------

  defp lock_table do
    case :ets.whereis(@lock_table) do
      :undefined ->
        ensure_lock_daemon()
        @lock_table

      _tab ->
        @lock_table
    end
  end

  # The named lock table must outlive every claimer: when it was owned by whichever
  # process happened to create it first, that process's death deleted the table and
  # silently released every held path lock (witnessed as a double-open passing the
  # concurrent-open refusal test). An unlinked daemon owns it for the node's lifetime.
  defp ensure_lock_daemon do
    ref = make_ref()
    me = self()

    daemon =
      :erlang.spawn(fn ->
        Process.flag(:trap_exit, true)

        try do
          :ets.new(@lock_table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

        send(me, {:lock_table_ready, ref})
        Process.sleep(:infinity)
      end)

    receive do
      {:lock_table_ready, ^ref} -> :ok
    after
      5_000 -> :ok
    end

    _ = daemon
    :ok
  end

  defp claim_path_lock(path) do
    tab = lock_table()
    now = System.monotonic_time()

    case :ets.insert_new(tab, {path, self(), now}) do
      true ->
        :ok

      false ->
        case :ets.lookup(tab, path) do
          [{^path, pid, _}] ->
            if is_pid(pid) and Process.alive?(pid) do
              {:error, {:path_in_use, path}}
            else
              :ets.insert(tab, {path, self(), now})
              :ok
            end

          [] ->
            claim_path_lock(path)
        end
    end
  end

  defp release_path_lock(path) do
    # the lock table is owned by whichever process created it first; if that owner died, the
    # table is gone - releasing into a missing table must not crash terminate
    case :ets.whereis(@lock_table) do
      :undefined -> :ok
      _tab -> :ets.delete(@lock_table, path)
    end
  end

  defp lookup(tab, key, default) do
    case :dets.lookup(tab, key) do
      [{_, v}] -> v
      [] -> default
    end
  end

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

    :ok = :dets.insert(st.tab, {{:cp, id, key}, cp})
    {{:ok, cp}, st}
  end

  defp fetch_run(st, id), do: lookup(st.tab, {:run, id}, nil)

  defp put_run(st, rec, attrs) do
    new =
      rec
      |> Map.merge(Map.drop(attrs, @protected_keys))
      |> Map.update!(:version, &(&1 + 1))

    :ok = :dets.insert(st.tab, {{:run, rec.id}, new})
    new
  end

  defp from_ok?(:any, status), do: not Status.terminal?(status)
  defp from_ok?(from, status) when is_list(from), do: status in from

  defp claimable?(%Record{claimed_at: nil}, _claimer, _lease, _now), do: true

  defp claimable?(%Record{claimed_by: by}, claimer, _lease, _now)
       when not is_nil(claimer) and by == claimer,
       do: true

  defp claimable?(%Record{claimed_at: at}, _claimer, lease, now),
    do: DateTime.compare(now, DateTime.add(at, lease || 0, :millisecond)) != :lt

  defp cps(st, id) do
    st.tab
    |> :dets.select([{{{:cp, id, :_}, :"$1"}, [], [:"$1"]}])
    |> Enum.sort_by(& &1.seq)
  end

  defp sigs(st, id) do
    st.tab
    |> :dets.select([{{{:sig, :_}, :"$1"}, [], [:"$1"]}])
    |> Enum.filter(&(&1.run_id == id))
    |> Enum.sort_by(& &1.seq)
  end

  defp insert_waiter(st, id, name, kind, deadline) do
    w = %Waiter{run_id: id, name: name, kind: kind, deadline: deadline}
    :ok = :dets.insert(st.tab, {{:waiter, id, name}, w})
    w
  end
end

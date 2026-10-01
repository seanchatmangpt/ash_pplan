defmodule AshPPlan.Reactor.Durable.Store.Ets do
  @moduledoc """
  In-memory `AshPPlan.Reactor.Durable.Store` backed by private ETS tables owned by one GenServer.

  Every operation is a `GenServer.call`, so the server's mailbox serialises all reads and writes:
  claim, transition, consume_signal, claim_undo and record (insert-or-adopt) are linearizable
  compare-and-set operations. Design derived from mbuhot/magma (MIT per its mix.exs).
  """
  use GenServer

  @behaviour AshPPlan.Reactor.Durable.Store

  alias AshPPlan.Reactor.Durable.{Checkpoint, Record, Signal, Status, Waiter}

  @protected_keys [:id, :version, :seq]

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

  @impl GenServer
  def init(_opts) do
    {:ok,
     %{
       runs: :ets.new(:runs, [:set, :private]),
       cps: :ets.new(:cps, [:set, :private]),
       signals: :ets.new(:signals, [:set, :private]),
       waiters: :ets.new(:waiters, [:set, :private]),
       leases: %{},
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
        if claimable?(rec, claimer, Map.get(st.leases, id), now) do
          new = put_run(st, rec, %{claimed_by: claimer, claimed_at: now})
          {{:ok, new}, %{st | leases: Map.put(st.leases, id, lease_ms)}}
        else
          {:taken, st}
        end
    end
  end

  defp do_call({:release_claim, id, claimer}, st) do
    case fetch_run(st, id) do
      %Record{claimed_by: ^claimer} = rec when not is_nil(claimer) ->
        put_run(st, rec, %{claimed_by: nil, claimed_at: nil})
        {:ok, %{st | leases: Map.delete(st.leases, id)}}

      _ ->
        {:ok, st}
    end
  end

  defp do_call({:checkpoints, id}, st),
    do: {Map.new(cps(st, id), &{&1.step_key, &1}), st}

  defp do_call({:standing, id}, st),
    do: {Enum.filter(cps(st, id), &is_nil(&1.undone_at)), st}

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

  defp do_call({:claim_undo, id, key, now}, st) do
    case :ets.lookup(st.cps, {id, key}) do
      [{k, %Checkpoint{undone_at: nil} = cp}] ->
        cp = %{cp | undone_at: now}
        :ets.insert(st.cps, {k, cp})
        {{:ok, cp}, st}

      _ ->
        {:taken, st}
    end
  end

  defp do_call({:release_undo, id, key}, st) do
    case :ets.lookup(st.cps, {id, key}) do
      [{k, cp}] -> :ets.insert(st.cps, {k, %{cp | undone_at: nil}})
      [] -> :ok
    end

    {:ok, st}
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
  defp from_ok?(from, status) when is_list(from), do: status in from

  defp claimable?(%Record{claimed_at: nil}, _claimer, _lease, _now), do: true

  defp claimable?(%Record{claimed_by: by}, claimer, _lease, _now)
       when not is_nil(claimer) and by == claimer,
       do: true

  defp claimable?(%Record{claimed_at: at}, _claimer, lease, now),
    do: DateTime.compare(now, DateTime.add(at, lease || 0, :millisecond)) != :lt

  defp cps(st, id) do
    for({{^id, _}, cp} <- :ets.tab2list(st.cps), do: cp)
    |> Enum.sort_by(& &1.seq)
  end

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

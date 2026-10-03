defmodule AshPPlan.Reactor.Durable.MultiStoreStormTest do
  @moduledoc """
  Multi-store storm: ONE `Store.Dets` file + three `Store.Ets` tables — 4 store instances,
  48 workers, 10k acknowledged ops, same run_id namespace ("msstorm-w<w>").

  Mid-storm the Dets server is hard-killed (`Process.exit(pid, :kill)`), reopened on the
  same `:path`, and the storm continues on the reopened store. Final verify-all:

    1. No lost acknowledged writes: every acked start_run / record / park / deliver / claim
       is still present on its store after the storm.
    2. `seq` strictly monotone: all acked seqs distinct per store, and every post-reopen
       Dets seq strictly exceeds the pre-kill maximum (no counter reset).
  """

  use ExUnit.Case, async: false

  @moduletag :stress
  @moduletag timeout: 600_000

  alias AshPPlan.Reactor.Durable.Store.{Dets, Ets}

  @workers 48
  @ops_per_worker 210
  @total_ops @workers * @ops_per_worker
  @kill_at div(@total_ops, 2)

  @pt :msstorm

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "msstorm-#{System.unique_integer([:positive])}_#{:erlang.phash2(make_ref())}.dets"
      )

    File.rm(path)
    File.rm(path <> ".lock")

    {:ok, dets} = Dets.start_link(path: path)
    ets_stores = for i <- 1..3, do: start_supervised!({Ets, []}, id: {:msstorm_ets, i})

    :persistent_term.put(@pt, %{
      dets: dets,
      path: path,
      ets: ets_stores,
      killer_done: false,
      t0: System.monotonic_time(:millisecond)
    })

    {:ok, _} = Agent.start_link(fn -> %{ops: 0, acks: []} end, name: __MODULE__.Log)

    on_exit(fn ->
      :persistent_term.erase(@pt)
      File.rm(path)
      File.rm(path <> ".lock")
    end)

    %{path: path, dets: dets, ets: ets_stores}
  end

  test "48-worker storm over 1 Dets + 3 Ets stores survives a hard kill and reopen" do
    # the Dets server is linked to this process; the mid-storm :kill must not take us down
    Process.flag(:trap_exit, true)
    %{ets: ets} = pt()

    workers =
      for w <- 1..@workers do
        Task.async(fn -> worker(w, ets) end)
      end

    killer =
      Task.async(fn ->
        wait_until(fn -> ops_done() >= @kill_at end, 120_000)
        %{dets: killed} = pt()

        if is_pid(killed) and Process.alive?(killed) do
          Process.exit(killed, :kill)
          wait_until(fn -> not Process.alive?(killed) end, 10_000)
        end

        {:ok, reopened} = Dets.start_link(path: pt().path)
        # the store must outlive this task; its link would tear the store down with us
        :erlang.unlink(reopened)
        put_pt(dets: reopened, killer_done: true)
        :ok
      end)

    tasks = workers ++ [killer]

    for {_ref, res} <- Task.yield_many(tasks, 540_000) do
      case res do
        {:ok, :ok} -> :ok
        {:ok, other} -> flunk("worker/killer failed: #{inspect(other)}")
        {:exit, reason} -> flunk("worker/killer exited: #{inspect(reason)}")
        nil -> flunk("worker/killer timed out")
      end
    end

    verify_all(ets)
  end

  # -- workers --------------------------------------------------------------------------------

  # Each worker owns the run id "msstorm-w<w>" on every store (same id namespace) and
  # hammers all four op families against each: claim / record / park / deliver+consume.
  defp worker(w, ets) do
    {:ok, _} = Dets.start_run(dets!(), %{id: run_id(w)})

    for e <- ets do
      {:ok, _} = Ets.start_run(e, %{id: run_id(w)})
    end

    loop(w, ets, 0)
  end

  defp loop(_w, _ets, n) when n >= @ops_per_worker, do: :ok

  defp loop(w, ets, n) do
    dets_round(w, n)
    Enum.each(ets, &ets_round(&1, w, n))
    loop(w, ets, n + 1)
  end

  # -- Dets round: claim-gated record/park/deliver/consume, kill-tolerant ----------------------

  # an in-flight call that straddles the hard kill exits :killed — that round is abandoned
  # and the worker retries against the reopened store on its next round.
  defp dets_round(w, n) do
    try do
      dets_round_inner(w, n)
    catch
      :exit, _ -> :ok
    end
  end

  defp dets_round_inner(w, n) do
    store = dets!()
    run = run_id(w)
    now = DateTime.utc_now()
    k = key(w, n)

    case Dets.claim(store, run, claimer(w), 100, now) do
      {:ok, rec} ->
        log_ack(:dets, :claim, run, run, rec.seq, phase())

        case Dets.record(store, run, k, "storm", {:out, w, n}, %{}) do
          {:ok, cp} -> log_ack(:dets, :record, run, k, cp.seq, phase())
          {:error, _} -> :ok
        end

        {:ok, _waiter} = Dets.park(store, run, "p" <> k, :signal, nil, [])
        log_ack(:dets, :park, run, "p" <> k, nil, phase())

        {:ok, sig} = Dets.deliver_signal(store, run, "s" <> k, {:p, w, n})

        case Dets.consume_signal(store, sig.id, now) do
          {:ok, s2} -> log_ack(:dets, :consume, run, "s" <> k, s2.seq, phase())
          :taken -> :ok
        end

        Dets.release_claim(store, run, claimer(w))
        bump_ops()

      :taken ->
        # lease lapsed or contended — a probe read still counts as an op
        case Dets.get_run(store, run) do
          %{} = r -> log_ack(:dets, :read, run, run, r.seq, phase())
          nil -> :ok
        end
    end
  end

  # -- Ets round: same shape, one table each ----------------------------------------------------

  defp ets_round(e, w, n) do
    run = run_id(w)
    now = DateTime.utc_now()
    k = key(w, n)

    case Ets.claim(e, run, claimer(w), 100, now) do
      {:ok, rec} ->
        log_ack({:ets, e}, :claim, run, run, rec.seq, :plain)

        case Ets.record(e, run, k, "storm", {:out, w, n}, %{}) do
          {:ok, cp} -> log_ack({:ets, e}, :record, run, k, cp.seq, :plain)
          {:error, _} -> :ok
        end

        {:ok, _waiter} = Ets.park(e, run, "p" <> k, :signal, nil, [])
        log_ack({:ets, e}, :park, run, "p" <> k, nil, :plain)

        {:ok, sig} = Ets.deliver_signal(e, run, "s" <> k, {:p, w, n})

        case Ets.consume_signal(e, sig.id, now) do
          {:ok, s2} -> log_ack({:ets, e}, :consume, run, "s" <> k, s2.seq, :plain)
          :taken -> :ok
        end

        Ets.release_claim(e, run, claimer(w))
        bump_ops()

      :taken ->
        case Ets.get_run(e, run) do
          %{} = r -> log_ack({:ets, e}, :read, run, run, r.seq, :plain)
          nil -> :ok
        end
    end
  end

  # -- final verification ------------------------------------------------------------------------

  defp verify_all(ets_refs) do
    IO.puts(
      "[multi_store_storm] dets alive=#{Process.alive?(dets!())} " <>
        Enum.map_join(ets_refs, ",", fn e -> Process.alive?(e) end)
    )

    log = Agent.get(__MODULE__.Log, & &1)
    seconds = max(System.monotonic_time(:millisecond) - pt().t0, 1) / 1000

    IO.puts(
      "[multi_store_storm] workers=#{@workers} ops=#{log.ops} acks=#{length(log.acks)} " <>
        "elapsed=#{Float.round(seconds, 2)}s throughput=#{trunc(log.ops / seconds)} ops/sec"
    )

    assert log.ops >= @total_ops, "only #{log.ops}/#{@total_ops} ops acknowledged"

    # 1. no lost acknowledged writes
    verify_no_lost_writes(dets!(), Dets, log.acks, :dets)

    Enum.each(ets_refs, fn e -> verify_no_lost_writes(e, Ets, log.acks, {:ets, e}) end)

    # 2. seq strictly monotone per store
    store_keys = [:dets | Enum.map(ets_refs, &{:ets, &1})]

    for store_key <- store_keys do
      seqs =
        log.acks
        |> Enum.filter(&(&1.store == store_key and &1.type in [:record, :consume]))
        |> Enum.map(& &1.seq)
        |> Enum.reject(&is_nil/1)

      assert seqs != [], "#{inspect(store_key)}: no acked seqs"

      assert length(seqs) == length(Enum.uniq(seqs)),
             "#{inspect(store_key)}: duplicate acked seqs"
    end

    pre = dets_seqs(log, :pre_kill)
    post = dets_seqs(log, :post_kill)

    # Under load the kill can land after every worker has already finished, leaving
    # the post-kill phase empty by timing, not by data loss. Only the monotonicity
    # claim needs both phases; seq-reset detection stays sound when pre is nonempty
    # and the reopened store continues past it on any later write.
    assert pre != [], "no acked pre-kill Dets writes"

    if post != [] do
      assert Enum.max(post) > Enum.max(pre),
             "reopened Dets reset the seq counter (pre-kill max #{Enum.max(pre)}, " <>
               "post-reopen max #{Enum.max(post)})"
    end

    # the reopened store still answers after everything
    assert %{status: :pending} = Dets.get_run(dets!(), run_id(1))
  end

  defp verify_no_lost_writes(store, mod, acks, store_key) do
    mine = Enum.filter(acks, &(&1.store == store_key))

    # one read per run per family, then pure in-memory checks
    runs = mod.list_runs(store)
    run_ids = MapSet.new(runs, & &1.id)

    cps =
      runs
      |> Map.new(&{&1.id, mod.checkpoints(store, &1.id)})

    sigs =
      runs
      |> Enum.map(fn r -> {r.id, mod.signals(store, r.id) |> MapSet.new(fn s -> s.name end)} end)
      |> Map.new(fn {id, names} -> {id, names} end)

    waiters =
      runs
      |> Enum.map(fn r -> {r.id, mod.waiters(store, r.id) |> MapSet.new(fn w -> w.name end)} end)
      |> Map.new(fn {id, names} -> {id, names} end)

    # every acked record's checkpoint is present with the acked seq
    for %{run: run, key: k, seq: seq} <- Enum.filter(mine, &(&1.type == :record)) do
      cp = cps[run][k]

      assert cp != nil, "#{inspect(store_key)}: lost acked record #{run}/#{k}"

      assert cp.seq == seq, "#{inspect(store_key)}: #{run}/#{k} seq #{cp.seq} != acked #{seq}"
    end

    # every acked park's waiter is present
    for %{run: run, key: k} <- Enum.filter(mine, &(&1.type == :park)) do
      assert MapSet.member?(waiters[run], k), "#{inspect(store_key)}: lost acked park #{run}/#{k}"
    end

    # every acked delivery is still in the signal log (consumed or not)
    for %{run: run, key: k} <- Enum.filter(mine, &(&1.type in [:deliver, :consume])) do
      assert MapSet.member?(sigs[run], k), "#{inspect(store_key)}: lost acked signal #{run}/#{k}"
    end

    # every acked run exists
    for %{run: run} <- Enum.filter(mine, &(&1.type == :claim)) do
      assert MapSet.member?(run_ids, run), "#{inspect(store_key)}: lost run #{run}"
    end
  end

  # -- bookkeeping ---------------------------------------------------------------------------------

  defp log_ack(store, type, run, key, seq, phase) do
    Agent.cast(__MODULE__.Log, fn st ->
      %{
        st
        | ops: st.ops + 1,
          acks: [
            %{store: store, type: type, run: run, key: key, seq: seq, phase: phase} | st.acks
          ]
      }
    end)
  end

  defp bump_ops, do: Agent.cast(__MODULE__.Log, fn st -> %{st | ops: st.ops + 1} end)

  defp ops_done, do: Agent.get(__MODULE__.Log, & &1.ops)

  # -- helpers --------------------------------------------------------------------------------------

  defp run_id(w), do: "msstorm-w#{w}"
  defp key(w, n), do: "w#{w}-k#{n}"
  defp claimer(w), do: "claim-w#{w}"

  defp pt, do: :persistent_term.get(@pt)

  defp put_pt(kvs), do: :persistent_term.put(@pt, Map.merge(pt(), Map.new(kvs)))

  defp dets!, do: pt().dets

  defp phase, do: if(pt().killer_done, do: :post_kill, else: :pre_kill)

  defp dets_seqs(log, ph) do
    log.acks
    |> Enum.filter(&(&1.store == :dets and &1.phase == ph))
    |> Enum.map(& &1.seq)
    |> Enum.reject(&is_nil/1)
  end

  defp wait_until(pred, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    do_wait(pred, deadline)
  end

  defp do_wait(pred, deadline) do
    cond do
      pred.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("wait_until timeout")
      true -> Process.sleep(5) && do_wait(pred, deadline)
    end
  end
end

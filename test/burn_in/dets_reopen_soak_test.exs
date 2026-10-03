defmodule AshPPlan.BurnIn.DetsReopenSoakTest do
  @moduledoc """
  BURN-IN lane: kill/reopen soak for `AshPPlan.Reactor.Durable.Store.Dets` after the
  `claim_path_lock/1` dead-owner purge fix.

  30 cycles on ONE real DETS file. Per cycle: open the store, drive 25 runs through the real
  `Engine` (checkpoints via the real step tape, half the runs park on `Steps.Await` and are
  signalled), then HARD-KILL the store at a seeded random offset while the writer is in
  flight, reopen the same path and verify:

    * every write the engine ACKed before the kill is intact (run row, seq, status, full
      5-step standing tape on completed runs),
    * the seq counter continues past every acked seq (no backwards / reset),
    * no hang: the whole cycle is wall-clock bounded (< 30s) and the writer task is awaited
      with an explicit timeout,
    * only typed outcomes are accepted from the engine; a crash exit from a store death is
      the one tolerated shape, and it still must not lose acked writes.

  Chicago-style: real DETS file, real process kill, real engine, assertions on real reopened
  state. Runs on the canonical checkout with `MIX_BUILD_ROOT=_build-hc5`.
  """

  use ExUnit.Case, async: false

  alias AshPPlan.Durable.LaneBFx
  alias AshPPlan.Reactor.Durable.Engine
  alias AshPPlan.Reactor.Durable.Store.Dets
  alias AshPPlan.Test.Effects

  Code.require_file("lane_b_fixture.exs", Path.join(__DIR__, "../durable"))

  @cycles 30
  @runs_per_cycle 25
  @cycle_budget_ms 30_000
  @writer_timeout 25_000

  @tag :burn_in
  # 30 cycles x (25 engine runs through per-call dets.sync) plus a reopen verification sweep
  @tag timeout: 600_000
  test "30 open/write/kill-mid-write/reopen cycles: zero acked-write loss, seq continues, no hang" do
    Process.flag(:trap_exit, true)
    LaneBFx.install_adapter!()

    path =
      Path.join(
        System.tmp_dir!(),
        "ash_pplan_soak_dets_#{System.unique_integer([:positive])}.dets"
      )

    on_exit(fn -> File.rm(path) end)

    t0 = System.monotonic_time(:millisecond)

    verdicts =
      for cycle <- 1..@cycles do
        {us, verdict} = :timer.tc(fn -> run_cycle(path, cycle) end)
        ms = div(us, 1000)
        assert ms < @cycle_budget_ms, "cycle #{cycle} took #{ms}ms (budget #{@cycle_budget_ms}ms)"
        line = "[burn_in] cycle #{cycle}: #{verdict} wall=#{ms}ms"
        IO.puts(line)
        {cycle, line}
      end

    total = System.monotonic_time(:millisecond) - t0
    IO.puts("[burn_in] #{@cycles} cycles in #{total}ms total")
    assert total < 600_000
    assert length(verdicts) == @cycles
  end

  # -- one cycle --------------------------------------------------------------------------------

  defp run_cycle(path, cycle) do
    # seeded per-cycle random: the kill offset differs by cycle but is reproducible
    :rand.seed(:exsss, {17, cycle, 2026})

    {:ok, s} = Dets.start_link(path: path)
    flush_exit()

    fx = :"soak_fx_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: fx)

    # expectations ledger, written by the writer task, read by this process after the reopen
    acks = String.to_atom("soak_acks_#{System.unique_integer([:positive])}")

    acks = :ets.new(acks, [:set, :public, :named_table])

    writer =
      Task.async(fn ->
        try do
          write_workload(s, fx, cycle, acks)
          :done
        catch
          # the store died mid-write: the tolerated shape. Everything acked BEFORE the exit
          # is durable and is verified against the reopened file below.
          :exit, _reason -> :crashed
        end
      end)

    offset = 25 + :rand.uniform(1500)
    Process.sleep(offset)
    kill_store(s)

    writer_result = Task.await(writer, @writer_timeout)
    assert writer_result in [:done, :crashed], "writer ended #{inspect(writer_result)}"
    :ok = flush_exit()

    # REOPEN the same path: the killed store's stale lock slot must be purged/taken over.
    {:ok, s2} = Dets.start_link(path: path)
    :ok = flush_exit()

    {intact, completed, max_seq} = verify_acked(s2, acks, cycle)

    # seq continuity: a fresh write must exceed every seq the engine ever acked
    {:ok, probe} =
      Dets.start_run(s2, %{id: "c#{cycle}-probe", model: :soak, bindings: %{probe: cycle}})

    assert probe.seq > max_seq,
           "cycle #{cycle}: seq went backwards #{probe.seq} <= #{max_seq}"

    # quiescent close so the next cycle can take the path lock
    :ok = GenServer.stop(s2)
    :ok = flush_exit()
    :ets.delete(acks)

    "kill@#{offset}ms writer=#{writer_result} acked_runs=#{intact} completed=#{completed} " <>
      "acked_seq=#{max_seq} probe_seq=#{probe.seq}"
  end

  # The real workload: 25 runs through the real Engine against the live store. Half the runs
  # park on Await and are signalled (checkpoint tape + park + signal path), the rest complete
  # straight through. Every ack is recorded; a store death surfaces as an exit that ends the
  # loop early.
  defp write_workload(s, fx, cycle, acks) do
    opts = [store_module: Dets]

    for j <- 1..@runs_per_cycle do
      id = "c#{cycle}-r#{j}"

      attrs =
        if rem(j, 3) == 0,
          do: LaneBFx.attrs(id, fx, kinds: %{integrate: :await}),
          else: LaneBFx.attrs(id, fx, [])

      {:ok, rec} = Engine.start(s, attrs, opts)
      ack_run(acks, id, rec.seq, :pending)

      if rem(j, 3) == 0 do
        assert {:parked, :waiting} = Engine.attempt(s, id, opts)
        ack_run(acks, id, nil, :waiting)

        {:ok, sig} = Engine.signal(s, id, "go", {:cycle, cycle, j})
        bump_seq(acks, sig.seq)

        assert {:completed, _} = Engine.attempt(s, id, opts)
        ack_run(acks, id, nil, :completed)
      else
        assert {:completed, _} = Engine.attempt(s, id, opts)
        ack_run(acks, id, nil, :completed)
      end
    end

    :ok
  end

  defp ack_run(acks, id, seq, status) do
    cur =
      case :ets.lookup(acks, {:run, id}) do
        [{{:run, ^id}, m}] -> m
        [] -> %{seq: nil, status: :pending}
      end

    m = %{seq: seq || cur.seq, status: status}
    :ets.insert(acks, {{:run, id}, m})
    if seq, do: bump_seq(acks, seq)
    :ok
  end

  defp bump_seq(acks, seq) do
    prev =
      case :ets.lookup(acks, :max_seq) do
        [{:max_seq, n}] -> n
        [] -> 0
      end

    if seq > prev, do: :ets.insert(acks, {:max_seq, seq})
    :ok
  end

  # After the reopen, every acked run must be on disk with its acked seq and status, and every
  # completed run must carry its full 5-step standing tape.
  defp verify_acked(s2, acks, cycle) do
    runs =
      acks
      |> :ets.tab2list()
      |> Enum.filter(fn
        {{:run, _}, _} -> true
        _ -> false
      end)
      |> Map.new(fn {{:run, id}, m} -> {id, m} end)

    assert map_size(runs) > 0, "cycle #{cycle}: writer acked nothing before the kill"

    max_seq =
      case :ets.lookup(acks, :max_seq) do
        [{:max_seq, n}] -> n
        [] -> 0
      end

    {intact, completed} =
      Enum.reduce(runs, {0, 0}, fn {id, m}, {i, c} ->
        run = Dets.get_run(s2, id)
        assert run, "cycle #{cycle}: ACKED run #{id} LOST across kill/reopen"
        assert run.seq == m.seq, "cycle #{cycle}: run #{id} seq #{run.seq} != acked #{m.seq}"

        # forward-progress only: the store may be durably AHEAD of the last ack (the kill can
        # land after the store synced a completion but before the writer recorded it), never behind
        # it, and a completed run always carries its full 5-step standing tape.
        cond do
          run.status == :completed ->
            tape = Engine.steps(s2, id, store_module: Dets)

            assert length(tape) == 5,
                   "cycle #{cycle}: run #{id} tape #{inspect(Enum.map(tape, & &1.step_key))}"

            assert m.status != :failed, "cycle #{cycle}: run #{id} regressed"
            {i + 1, c + 1}

          m.status == :completed ->
            flunk("cycle #{cycle}: acked-completed run #{id} is #{inspect(run.status)}")

          true ->
            assert run.status in [:pending, :waiting],
                   "cycle #{cycle}: run #{id} status #{inspect(run.status)} not a valid parked/pending state"

            assert forward?(m.status, run.status),
                   "cycle #{cycle}: run #{id} status #{inspect(run.status)} behind acked #{inspect(m.status)}"

            {i + 1, c}
        end
      end)

    {intact, completed, max_seq}
  end

  defp forward?(:pending, s), do: s in [:pending, :waiting]
  defp forward?(:waiting, s), do: s == :waiting
  defp forward?(:completed, _), do: true

  defp kill_store(s) do
    pid =
      case s do
        pid when is_pid(pid) -> pid
        name when is_atom(name) -> Process.whereis(name)
      end

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000

    receive do
      {:EXIT, ^pid, _} -> :ok
    after
      0 -> :ok
    end

    :ok
  end

  # the test process traps exits (it start_link'd the killed store); drain any pending EXIT
  defp flush_exit do
    receive do
      {:EXIT, _pid, _reason} -> flush_exit()
    after
      0 -> :ok
    end
  end
end

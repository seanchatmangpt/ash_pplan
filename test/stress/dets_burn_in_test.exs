defmodule AshPPlan.Stress.DetsBurnInTest do
  @moduledoc """
  STRESS lane: burn-in loop for `AshPPlan.Reactor.Durable.Store.Dets`.

  Repeated cycle: start a store on one DETS file, write runs + checkpoints + signals,
  interleave cancels and signal consumes across cycles, hard-kill the store process
  (`Process.exit(pid, :kill)` — untrappable, so `terminate/2` never runs and only the
  per-call `:dets.sync/1` guarantees durability), reopen the same path and assert every
  committed run intact and `:seq` continues monotonically.

  Fail-closed regression: a corrupt file must refuse to open (`{:error, {:dets_open_failed, _}}`),
  not silently come back empty.

  Chicago-style: real DETS file, real process kill, assertions on real reopened state.
  """

  use ExUnit.Case, async: true

  alias AshPPlan.Reactor.Durable.Store.Dets

  @t0 ~U[2026-01-01 00:00:00.000Z]
  @restarts 8
  @runs_per_cycle 12

  setup do
    # we start_link the store, so its (deliberate) hard-kill EXIT must not kill the test
    Process.flag(:trap_exit, true)
    :ok
  end

  @tag :stress
  # 8 kill/reopen cycles x per-call dets.sync over 100+ runs routinely exceeds the 60s
  # default timeout on a loaded machine; the work itself is deterministic
  @tag timeout: 300_000
  test "burn-in: #{@restarts} write/kill/reopen cycles keep every committed row; seq continues" do
    path =
      Path.join(System.tmp_dir!(), "ash_pplan_stress_dets_#{System.unique_integer([:positive])}.dets")

    on_exit(fn -> File.rm(path) end)

    expected = burn_in_loop(path, _cycle = 1, _expected = %{})

    # Final verification pass on one more fresh open of the same file.
    {:ok, s} = Dets.start_link(path: path)
    runs = Dets.list_runs(s)
    assert length(runs) == @restarts * (@runs_per_cycle + 1)
    verify_all(s, expected)
  end

  # One cycle: open -> verify survivors -> write -> kill. Returns accumulated expectations.
  defp burn_in_loop(path, cycle, expected) do
    {:ok, s} = Dets.start_link(path: path)

    # 1. every run committed before the kill is intact after the reopen
    for {id, exp} <- expected do
      run = Dets.get_run(s, id)
      assert run != nil, "run #{id} lost across restart (cycle #{cycle})"
      assert run.status == exp.status, "run #{id}: #{inspect(run.status)} != #{inspect(exp.status)}"
      assert run.bindings == exp.bindings, "run #{id}: bindings changed across restart"

      if exp.checkpoint do
        cp = Dets.checkpoints(s, id)[exp.checkpoint.key]
        assert cp, "checkpoint on #{id} lost across restart"
        assert cp.output == exp.checkpoint.output, "checkpoint on #{id} corrupted across restart"
      end
    end

    # 2. seq continued: this cycle's first write must exceed the highest seq ever returned
    max_seq = expected |> Map.values() |> Map.new(&{&1.seq, true}) |> Map.keys() |> Enum.max(fn -> 0 end)

    {:ok, first} = Dets.start_run(s, %{id: "c#{cycle}-probe", model: :stress, bindings: %{probe: cycle}})
    assert first.seq > max_seq, "seq went backwards: #{first.seq} <= #{max_seq}"

    # 3. write this cycle's committed set
    cycle_expected =
      for i <- 1..@runs_per_cycle, reduce: %{seqs: [first.seq], runs: %{}} do
        acc ->
          id = "c#{cycle}-r#{i}"
          {:ok, rec} = Dets.start_run(s, %{id: id, model: :stress, bindings: %{cycle: cycle, i: i}})
          assert rec.seq > hd(acc.seqs)

          output = %{cycle: cycle, i: i, blob: String.duplicate("x", 128)}
          {:ok, _} = Dets.record(s, id, "step", "burn", output, %{})

          {status, consumed?} =
            if rem(i, 3) == 0 do
              # interleaved cancel: pending -> cancelling -> cancelled
              {:ok, _} = Dets.transition(s, id, :any, :cancelling, %{})
              {:ok, _} = Dets.transition(s, id, :any, :cancelled, %{})
              {:cancelled, false}
            else
              {:ok, sig} = Dets.deliver_signal(s, id, "go", {:cycle, cycle})

              if rem(i, 2) == 0 do
                {:ok, _} = Dets.consume_signal(s, sig.id, @t0)
                {:pending, true}
              else
                # leave one pending signal per odd run; asserted below after restarts
                {:pending, false}
              end
            end

          %{
            acc
            | seqs: [rec.seq | acc.seqs],
              runs: Map.put(acc.runs, id, %{
                seq: rec.seq,
                status: status,
                consumed: consumed?,
                bindings: %{cycle: cycle, i: i},
                checkpoint: %{key: "step", output: output}
              })
          }
      end

    # a waiter per cycle, to prove park state survives the kill
    {:ok, _} = Dets.park(s, "c#{cycle}-r1", "w", :poll, DateTime.add(@t0, 5_000, :millisecond), [])

    expected =
      Map.merge(expected, cycle_expected.runs)
      |> Map.put("c#{cycle}-probe", %{
        seq: first.seq,
        status: :pending,
        consumed: false,
        bindings: %{probe: cycle},
        checkpoint: nil
      })

    # HARD KILL: untrappable exit, terminate/2 never runs, only per-call sync protects us
    kill_store(s)

    burn_in_loop(path, cycle + 1, expected)
  end

  defp verify_all(s, expected) do
    for {id, exp} <- expected do
      run = Dets.get_run(s, id)
      assert run, "run #{id} lost"
      assert run.seq == exp.seq, "run #{id}: seq #{run.seq} != #{exp.seq}"
      assert run.status == exp.status
      assert run.bindings == exp.bindings

      if exp.checkpoint do
        assert Dets.checkpoints(s, id)[exp.checkpoint.key].output == exp.checkpoint.output
      end

      # signal consumption state survives the kill exactly as committed
      got = Dets.pending_signal(s, id, "go")

      if exp.consumed or exp.status == :cancelled do
        refute got, "run #{id}: expected no pending signal after restart"
      else
        assert got, "run #{id}: pending signal lost across restart"
      end
    end

    # waiters survived every kill
    for cycle <- 1..@restarts do
      assert Dets.get_waiter(s, "c#{cycle}-r1", "w"), "waiter for cycle #{cycle} lost"
    end

    # pending signals delivered before kills are still pending afterwards
    pending_count =
      for cycle <- 1..@restarts, i <- 1..@runs_per_cycle, rem(i, 3) != 0 and rem(i, 2) != 0 do
        sig = Dets.pending_signal(s, "c#{cycle}-r#{i}", "go")
        assert sig, "pending signal lost for c#{cycle}-r#{i}"
        sig.id
      end

    assert length(pending_count) ==
             @restarts * (Enum.count(1..@runs_per_cycle, &(rem(&1, 3) != 0 and rem(&1, 2) != 0)))

    # seq continuity end-to-end: one more write still exceeds every stored seq
    {:ok, tail} = Dets.start_run(s, %{id: "final-probe", model: :stress, bindings: %{
      tail: true
    }})
    max_seq = expected |> Map.values() |> Enum.map(& &1.seq) |> Enum.max()
    assert tail.seq > max_seq, "seq not continuing after #{@restarts} kills"
  end

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

  @tag :stress
  test "corrupt file fails closed: open returns error, never a silently-empty store" do
    path =
      Path.join(System.tmp_dir!(), "ash_pplan_stress_corrupt_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(path) end)

    # garbage where the DETS header/magic would be
    File.write!(path, :binary.copy(<<0xDE, 0xAD, 0xBE, 0xEF>>, 64))

    # the store traps exits inside init, which breaks start_link's own {:stop, _}
    # propagation (the caller's link is no longer auto-handled), so probe through a
    # trapping proxy instead of crashing this test process
    result =
      Task.async(fn ->
        Process.flag(:trap_exit, true)
        Dets.start_link(path: path)
      end)
      |> Task.await(5_000)

    assert {:error, {:dets_open_failed, _reason}} = result
  end
end

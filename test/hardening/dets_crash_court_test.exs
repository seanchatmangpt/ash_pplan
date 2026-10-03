defmodule AshPPlan.Reactor.Durable.DetsCrashCourtTest do
  @moduledoc """
  Adversarial DETS court for `AshPPlan.Reactor.Durable.Store.Dets`. Chicago discipline: every
  assertion lands on real DETS files and real process deaths, no mocks.

  Laws under judgment:

    1. Concurrent open of the same path from N racers yields exactly one winner; every loser
       gets a typed refusal `{:error, {:path_in_use, path}}`. The race includes the
       dead-owner takeover path, where two racers may both see a dead pid - only one may win.
    2. Garbage paths are typed refusals, never crashes and never silent success: a nonexistent
       directory and a permission-denied directory both return
       `{:error, {:dets_open_failed, _}}`, leave no orphan path lock (a later open of the same
       path once it becomes valid succeeds), and do not kill the test process.
    3. Kill during a write burst, then reopen: every acknowledged write (the caller saw the
       `{:ok, _}` reply) is intact, no orphan path lock remains, and the sequence counter
       continues past the highest acknowledged seq - no id reuse.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Reactor.Durable.Store.Dets

  setup do
    # failed start_link exits children non-normally; trap so the assert decides
    Process.flag(:trap_exit, true)

    path =
      Path.join(
        System.tmp_dir!(),
        "ash_pplan_court_#{System.unique_integer([:positive])}_#{:erlang.phash2(make_ref())}.dets"
      )

    on_exit(fn -> File.rm(path) end)
    Process.put(:court_path, path)
    %{path: path}
  end

  # -- law 1: concurrent open -------------------------------------------------------------------

  test "N racers on one path: exactly one winner, typed refusals for the rest" do
    path = get_ctx(:path)
    me = self()

    # launchers are raw spawns that HOLD parentage of a winning store until released:
    # the previous unlink-then-exit adoption raced the exit signal in flight (erlang:unlink/1
    # does not drain in-flight signals), and the trap_exit GenServer then terminated on its
    # parent's :normal exit - witnessed as GenServer.call -> EXIT normal on start_run
    racers =
      for _ <- 1..12 do
        spawn(fn ->
          Process.flag(:trap_exit, true)

          case Dets.start_link(path: path) do
            {:ok, pid} ->
              send(me, {:racer, self(), {:ok, pid}})

              receive do
                :released -> :ok
              end

            error ->
              send(me, {:racer, self(), error})
          end
        end)
      end

    results = collect_racers(12, [])

    winners =
      Enum.filter(results, fn
        {:ok, pid} when is_pid(pid) -> true
        _ -> false
      end)

    losers = results -- winners

    assert length(winners) == 1,
           "expected exactly one winner, got #{inspect(results, pretty: true)}"

    # losers: typed refusal only - either the path lock refused them or (for a racer whose
    # lock claim raced the winner's table creation) DETS's own double-open is still refused
    # downstream by the lock retry; whatever happens, no loser may see a crash exit
    assert Enum.all?(losers, fn
             {:error, {:path_in_use, _}} -> true
             {:error, {:dets_open_failed, _}} -> false
             other -> flunk("loser got #{inspect(other)}")
           end)

    {:ok, winner} = hd(winners)
    {:ok, _} = Dets.start_run(winner, %{id: "r1", model: :m, bindings: %{}})

    # winner is healthy, then frees the path on clean stop
    GenServer.stop(winner, :normal)
    {:ok, s2} = Dets.start_link(path: path)
    assert Dets.get_run(s2, "r1").id == "r1"
    GenServer.stop(s2, :normal)

    release_racers(racers)
  end

  test "dead-owner takeover race: two racers onto a killed owner's path, one winner" do
    path = get_ctx(:path)
    me = self()

    {:ok, s} = Dets.start_link(path: path)
    {:ok, _} = Dets.start_run(s, %{id: "r1", model: :m, bindings: %{}})

    Process.unlink(s)
    ref = Process.monitor(s)
    Process.exit(s, :kill)
    assert_receive {:DOWN, ^ref, :process, ^s, :killed}

    racers =
      for _ <- 1..8 do
        spawn(fn ->
          Process.flag(:trap_exit, true)

          case Dets.start_link(path: path) do
            {:ok, pid} ->
              send(me, {:racer, self(), {:ok, pid}})

              receive do
                :released -> :ok
              end

            error ->
              send(me, {:racer, self(), error})
          end
        end)
      end

    results = collect_racers(8, [])

    winners = Enum.filter(results, &match?({:ok, pid} when is_pid(pid), &1))
    losers = results -- winners

    assert length(winners) == 1, "takeover race produced #{inspect(results, pretty: true)}"

    assert Enum.all?(losers, &match?({:error, {:path_in_use, _}}, &1)),
           "loser refusals not typed: #{inspect(losers, pretty: true)}"

    {:ok, winner} = hd(winners)
    assert Dets.get_run(winner, "r1").id == "r1"
    GenServer.stop(winner, :normal)

    release_racers(racers)
  end

  # -- law 2: garbage paths ---------------------------------------------------------------------

  test "nonexistent directory: typed refusal, no orphan lock" do
    bad = Path.join([System.tmp_dir!(), "no_such_dir_court", "x.dets"])

    assert {:error, {:dets_open_failed, _}} = Dets.start_link(path: bad)

    # no orphan lock: once the directory exists, the same path opens cleanly
    File.mkdir_p!(Path.dirname(bad))
    on_exit(fn -> File.rm_rf(Path.dirname(bad)) end)

    {:ok, s} = Dets.start_link(path: bad)
    {:ok, _} = Dets.start_run(s, %{id: "r1", model: :m, bindings: %{}})
    GenServer.stop(s, :normal)
  end

  test "permission-denied directory: typed refusal, no orphan lock" do
    if uid() == 0, do: throw(:skip_root)

    dir =
      Path.join(
        System.tmp_dir!(),
        "ash_pplan_denied_#{System.unique_integer([:positive])}_#{:erlang.phash2(make_ref())}"
      )

    File.mkdir_p!(dir)
    File.chmod!(dir, 0o000)
    on_exit(fn -> restore_and_rm(dir) end)

    bad = Path.join(dir, "x.dets")
    assert {:error, {:dets_open_failed, _}} = Dets.start_link(path: bad)

    # lock released on the failed open: chmod back and the same path opens
    File.chmod!(dir, 0o755)
    {:ok, s} = Dets.start_link(path: bad)
    assert {:ok, _} = Dets.start_run(s, %{id: "r1", model: :m, bindings: %{}})
    GenServer.stop(s, :normal)
  end

  # -- law 3: kill during write burst -----------------------------------------------------------

  test "kill mid-burst: every acknowledged write intact, lock free, seq continues" do
    path = get_ctx(:path)
    {:ok, s} = Dets.start_link(path: path)
    {:ok, _} = Dets.start_run(s, %{id: "r1", model: :m, bindings: %{}})

    me = self()

    # raw spawned tasks run eagerly; an unconsumed Task.async_stream would never start
    Enum.each(1..200, fn n ->
      Task.start(fn ->
        case Dets.deliver_signal(s, "r1", "go#{n}", n) do
          {:ok, sig} ->
            {:ok, _cp} = Dets.record(s, "r1", "k#{n}", "l", n, %{})
            send(me, {:acked, sig.id, sig.seq})

          _ ->
            :ok
        end
      end)
    end)

    # deterministic mid-burst kill: wait for at least one acknowledged write WITHOUT
    # consuming it (consuming it let the kill land on an empty ack set), then kill
    # immediately - the burst is still mid-flight at that point
    wait_for_ack(500)
    Process.unlink(s)
    down = Process.monitor(s)
    Process.exit(s, :kill)
    assert_receive {:DOWN, ^down, :process, ^s, :killed}

    # every acknowledgment whose reply round-tripped before the kill is in this mailbox
    acked = drain_acked([])

    assert acked != [], "kill landed before any write was acknowledged - rerun"

    {:ok, s2} = Dets.start_link(path: path)

    # every acknowledged signal is intact on the reopened file
    sigs = Dets.signals(s2, "r1")
    by_id = Map.new(sigs, &{&1.id, &1})

    Enum.each(acked, fn {id, seq} ->
      assert sig = by_id[id], "acknowledged signal #{id} lost after reopen"
      assert sig.seq == seq
    end)

    assert length(sigs) >= length(acked)

    # seq continues: no acknowledged id is ever reused
    {:ok, sig} = Dets.deliver_signal(s2, "r1", "after", 0)
    max_acked = acked |> Enum.map(fn {id, _} -> id end) |> Enum.max()
    assert sig.id > max_acked

    # no orphan lock: reopen again on the same path after a clean stop
    GenServer.stop(s2, :normal)
    {:ok, s3} = Dets.start_link(path: path)
    assert Dets.get_run(s3, "r1").id == "r1"
    GenServer.stop(s3, :normal)
  end

  # -- helpers ----------------------------------------------------------------------------------

  defp drain_acked(acc) do
    receive do
      {:acked, id, seq} -> drain_acked([{id, seq} | acc])
    after
      2_000 -> Enum.reverse(acc)
    end
  end

  defp collect_racers(0, acc), do: Enum.reverse(acc)

  defp collect_racers(n, acc) do
    receive do
      {:racer, _launcher, result} -> collect_racers(n - 1, [result | acc])
    after
      60_000 -> flunk("racers did not all report: got #{length(acc)}")
    end
  end

  # launchers of losing racers have already exited; sending to a dead pid is a no-op
  defp release_racers(racers), do: Enum.each(racers, &send(&1, :released))

  defp wait_for_ack(0), do: flunk("burst stalled: no write acknowledged within 5s")

  defp wait_for_ack(attempts_left) do
    has_ack? =
      self()
      |> Process.info(:messages)
      |> elem(1)
      |> Enum.any?(&match?({:acked, _, _}, &1))

    unless has_ack? do
      Process.sleep(10)
      wait_for_ack(attempts_left - 1)
    end
  end

  defp uid do
    case System.cmd("id", ["-u"]) do
      {out, 0} -> String.trim(out)
      _ -> "0"
    end
  end

  defp restore_and_rm(dir) do
    File.chmod(dir, 0o755)
    File.rm_rf(dir)
    :ok
  end

  # ExUnit context without the macro noise: read the setup-provided path from the process
  # dictionary is not available here, so tests pull it via the test context binding
  defp get_ctx(_key), do: Process.get(:court_path) || raise("court path not set")
end

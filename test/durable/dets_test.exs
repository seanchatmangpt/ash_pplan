defmodule AshPPlan.Reactor.Durable.DetsTest do
  @moduledoc """
  Court for `AshPPlan.Reactor.Durable.Store.Dets` path-lock daemon resilience and lock-table
  invariants (`dets-lock-resilience`).

  Chicago discipline: real DETS files, real BEAM processes, real `:kill` exits, zero mocks.
  `async: false` because this court intentionally kills the node-local `PathLock` owner,
  supervisor, and ETS table to prove recovery and zero orphan-daemon leaks.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AshPPlan.Reactor.Durable.Store.Dets

  @lock_table AshPPlan.Reactor.Durable.Store.Dets.PathLock
  @lock_sup AshPPlan.Reactor.Durable.Store.Dets.PathLock.Supervisor
  @lock_primary AshPPlan.Reactor.Durable.Store.Dets.PathLock.Primary
  @lock_heir AshPPlan.Reactor.Durable.Store.Dets.PathLock.Heir

  setup do
    Process.flag(:trap_exit, true)

    path =
      Path.join(
        System.tmp_dir!(),
        "ash_pplan_dets_lock_#{System.unique_integer([:positive])}_#{:erlang.phash2(make_ref())}.dets"
      )

    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  test "lock table survives repeated hard kills of its ETS owner via supervised mutual-heir handoff",
       %{path: path} do
    {:ok, s1} = Dets.start_link(path: path)
    {:ok, _} = Dets.start_run(s1, %{id: "r1", model: :m, bindings: %{ok: true}})

    assert :ets.whereis(@lock_table) != :undefined
    assert is_pid(Process.whereis(@lock_sup))

    for round <- 1..5 do
      owner = await_owner(3_000)
      heir = await_heir(3_000)
      assert is_pid(owner) and is_pid(heir) and owner != heir, "round #{round}: missing heir"

      ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^owner, :killed}, 2_000

      # Table and active lock entry survive the owner's untrappable kill without dropping slots.
      assert :ets.whereis(@lock_table) != :undefined

      assert {:error, {:path_in_use, _}} = Dets.start_link(path: path),
             "round #{round}: second open was not refused after killing PathLock owner"
    end

    # Supervisor restarts killed keepers and re-establishes mutual heir protection.
    assert is_pid(await_heir(2_000))
    assert Dets.get_run(s1, "r1").id == "r1"

    GenServer.stop(s1, :normal)

    {:ok, s2} = Dets.start_link(path: path)
    assert Dets.get_run(s2, "r1").bindings == %{ok: true}
    GenServer.stop(s2, :normal)
  end

  test "explicit PathLock ETS deletion and supervisor kill rehydrate active locks from live DETS tables",
       %{path: path} do
    {:ok, s1} = Dets.start_link(path: path)
    {:ok, _} = Dets.start_run(s1, %{id: "r-rehydrate", model: :m, bindings: %{}})

    # Case A: direct deletion of the named ETS table while supervisor stays up.
    :ets.delete(@lock_table)
    assert :ets.whereis(@lock_table) == :undefined

    assert {:error, {:path_in_use, _}} = Dets.start_link(path: path)
    assert :ets.whereis(@lock_table) != :undefined

    # Case B: hard kill of the PathLock supervisor tree itself while s1 remains open.
    capture_log(fn ->
      kill_lock_supervisor_tree()
    end)

    assert {:error, {:path_in_use, _}} = Dets.start_link(path: path)
    assert is_pid(Process.whereis(@lock_sup))
    assert is_pid(await_heir(2_000))

    # Once s1 stops cleanly, its path lock releases and a fresh store opens cleanly.
    GenServer.stop(s1, :normal)
    {:ok, s2} = Dets.start_link(path: path)
    assert Dets.get_run(s2, "r-rehydrate").id == "r-rehydrate"
    GenServer.stop(s2, :normal)
  end

  test "ephemeral caller exit does not destroy PathLock or kill the lock daemon", %{path: path} do
    teardown_lock_daemon()
    me = self()

    caller =
      spawn(fn ->
        {:ok, s} = Dets.start_link(path: path)
        {:ok, _} = Dets.start_run(s, %{id: "ephemeral", model: :m, bindings: %{}})
        GenServer.stop(s, :normal)
        send(me, :caller_done)
        exit(:shutdown)
      end)

    ref = Process.monitor(caller)
    assert_receive :caller_done, 5_000
    assert_receive {:DOWN, ^ref, :process, ^caller, :shutdown}, 5_000

    assert :ets.whereis(@lock_table) != :undefined
    assert is_pid(Process.whereis(@lock_sup))
    assert is_pid(Process.whereis(@lock_primary))
    assert is_pid(Process.whereis(@lock_heir))

    {:ok, s2} = Dets.start_link(path: path)
    assert Dets.get_run(s2, "ephemeral").id == "ephemeral"
    GenServer.stop(s2, :normal)
  end

  test "concurrent cold-start open burst spawns exactly one supervised pair with zero orphan daemons",
       %{path: base_path} do
    teardown_lock_daemon()
    Process.sleep(20)

    before_pids = MapSet.new(Process.list())
    me = self()

    paths =
      for i <- 1..16 do
        p = "#{base_path}.cold_#{i}"
        on_exit(fn -> File.rm(p) end)
        p
      end

    racers =
      for p <- paths do
        spawn(fn ->
          {:ok, s} = Dets.start_link(path: p)
          GenServer.stop(s, :normal)
          send(me, {:cold_done, self()})
        end)
      end

    for r <- racers do
      ref = Process.monitor(r)
      assert_receive {:cold_done, ^r}, 10_000
      assert_receive {:DOWN, ^ref, :process, ^r, _}, 5_000
    end

    Process.sleep(20)
    after_pids = MapSet.new(Process.list())
    new_pids = MapSet.difference(after_pids, before_pids)

    expected_lock_pids =
      [@lock_sup, @lock_primary, @lock_heir]
      |> Enum.map(&Process.whereis/1)
      |> Enum.filter(&is_pid/1)
      |> MapSet.new()

    assert MapSet.size(expected_lock_pids) == 3

    leaked =
      new_pids
      |> MapSet.difference(expected_lock_pids)
      |> Enum.filter(fn pid ->
        case Process.info(pid, :current_function) do
          {:current_function, {Process, :sleep, _}} -> true
          {:current_function, {:timer, :sleep, _}} -> true
          _ -> false
        end
      end)

    assert leaked == [],
           "concurrent ensure_lock_daemon leaked sleeping daemon processes: #{inspect(leaked)}"
  end

  test "dead-owner ABA takeover admits one winner and failed open never deletes live owner's lock",
       %{path: path} do
    # Ensure daemon is up and seed a genuinely dead PID slot at the expanded charlist path.
    {:ok, seed} = Dets.start_link(path: path)
    GenServer.stop(seed, :normal)

    dead_pid = spawn(fn -> :ok end)
    ref = Process.monitor(dead_pid)
    assert_receive {:DOWN, ^ref, :process, ^dead_pid, _}, 1_000

    expanded = path |> Path.expand() |> to_charlist()
    true = :ets.insert(@lock_table, {expanded, dead_pid, System.monotonic_time()})

    me = self()

    racers =
      for _ <- 1..16 do
        spawn(fn ->
          Process.flag(:trap_exit, true)

          case Dets.start_link(path: path) do
            {:ok, pid} ->
              send(me, {:takeover_racer, {:ok, pid}})

              receive do
                :release -> :ok
              end

            err ->
              send(me, {:takeover_racer, err})
          end
        end)
      end

    results =
      for _ <- 1..16 do
        assert_receive {:takeover_racer, res}, 10_000
        res
      end

    winners = Enum.filter(results, &match?({:ok, pid} when is_pid(pid), &1))
    losers = results -- winners

    assert [{:ok, winner}] = winners
    assert length(losers) == 15
    assert Enum.all?(losers, &match?({:error, {:path_in_use, _}}, &1))

    # Slot in PathLock retains the 3-tuple `{charlist_path, winner_pid, tick}` shape.
    assert [{^expanded, ^winner, tick}] = :ets.lookup(@lock_table, expanded)
    assert is_integer(tick)

    GenServer.stop(winner, :normal)
    Enum.each(racers, &send(&1, :release))
  end

  defp teardown_lock_daemon do
    if sup = Process.whereis(@lock_sup) do
      try do
        Supervisor.stop(sup, :shutdown, 2_000)
      catch
        :exit, _ -> :ok
      end
    end

    kill_lock_supervisor_tree()
  end

  defp kill_lock_supervisor_tree do
    if sup = Process.whereis(@lock_sup) do
      ref = Process.monitor(sup)
      Process.exit(sup, :kill)
      assert_receive {:DOWN, ^ref, :process, ^sup, _}, 2_000
    end

    for name <- [@lock_primary, @lock_heir] do
      if pid = Process.whereis(name) do
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
      end
    end

    if :ets.whereis(@lock_table) != :undefined do
      try do
        :ets.delete(@lock_table)
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  defp await_owner(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_until(deadline, fn -> :ets.info(@lock_table, :owner) end)
  end

  defp await_heir(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_until(deadline, fn -> :ets.info(@lock_table, :heir) end)
  end

  defp poll_until(deadline, fun) do
    case fun.() do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: pid, else: retry_poll(deadline, fun)

      _ ->
        retry_poll(deadline, fun)
    end
  end

  defp retry_poll(deadline, fun) do
    if System.monotonic_time(:millisecond) >= deadline do
      fun.()
    else
      Process.sleep(10)
      poll_until(deadline, fun)
    end
  end
end

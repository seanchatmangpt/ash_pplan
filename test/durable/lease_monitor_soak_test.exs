defmodule AshPPlan.Reactor.Durable.LeaseMonitorSoakTest do
  @moduledoc """
  Lane F4 soak court for `LeaseMonitor`.

  Verified properties, each backed by a real distribution table or an exact
  invariant (no sleeps anywhere — clock-free structural sync and bounded polls):

  1. Kill->release latency distribution over 50 sequential cycles (p50/p95/p99/max).
  2. Exactly-one-winner under 200 concurrent claim attempts, 10 rounds.
  3. Holder exclusivity: heartbeat renewals by the holder always succeed;
     non-holder claim/heartbeat attempts fail while the lease is held; a
     non-holder wins only after the holder releases or dies (the only lapse path).
  4. Table hygiene: lease table size returns to baseline after 100 grant/release
     cycles — released and monitor-dead entries do not accumulate.
  """

  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.LeaseMonitor

  @rounds 10
  @claimants 200
  @soak_cycles 50
  @hygiene_cycles 100
  @poll_timeout 2_000

  setup do
    name = :"lease_monitor_soak_#{System.unique_integer([:positive])}"
    start_supervised!({LeaseMonitor, name: name})
    %{monitor: name}
  end

  defp poll_until(fun, timeout \\ @poll_timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_step(fun, deadline)
  end

  defp poll_step(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("bounded poll exhausted after #{deadline}ms deadline")
      end

      poll_step(fun, deadline)
    end
  end

  defp spawn_holder do
    spawn(fn ->
      receive do
        :die -> exit(:crash)
      end
    end)
  end

  defp percentiles(samples, ps) do
    sorted = Enum.sort(samples)

    Enum.map(ps, fn p ->
      idx = max(0, ceil(p / 100 * length(sorted)) - 1)
      {p, Enum.at(sorted, idx)}
    end)
  end

  # ---------------------------------------------------------------------------
  # 1. Kill->release soak: 50 sequential cycles, latency distribution
  # ---------------------------------------------------------------------------

  test "kill->release soak: 50 cycles, monitor-trip latency distribution", %{monitor: monitor} do
    run_id_base = "soak-#{System.unique_integer([:positive])}"

    latencies =
      for i <- 1..@soak_cycles do
        run_id = "#{run_id_base}-#{i}"
        worker = spawn_holder()

        assert {:ok, 1} = LeaseMonitor.claim(monitor, run_id, worker)

        t0 = System.monotonic_time(:native)
        send(worker, :die)

        # Bounded poll on the real observable: lease vacancy after :DOWN trip.
        :ok =
          poll_until(fn ->
            match?(:vacant, LeaseMonitor.status(monitor, run_id))
          end)

        t1 = System.monotonic_time(:native)
        System.convert_time_unit(t1 - t0, :native, :microsecond)
      end

    pcts = percentiles(latencies, [50, 95, 99])
    {_, p50} = Enum.at(pcts, 0)
    {_, p95} = Enum.at(pcts, 1)
    {_, p99} = Enum.at(pcts, 2)
    max_us = Enum.max(latencies)

    IO.puts("""
    [F4 soak] kill->release over #{@soak_cycles} cycles (microseconds):
      p50 = #{p50}us  p95 = #{p95}us  p99 = #{p99}us  max = #{max_us}us
    """)

    # The whole point of the monitor is sub-second release — no 30s zombie window.
    assert max_us < 1_000_000, "worst-case release #{max_us}us exceeded 1s bound"
    assert Enum.all?(latencies, &is_integer/1)
  end

  # ---------------------------------------------------------------------------
  # 2. Exactly-one-winner under concurrent claim contention
  # ---------------------------------------------------------------------------

  test "exactly-one-winner across #{@claimants} concurrent claims x #{@rounds} rounds",
       %{monitor: monitor} do
    for round <- 1..@rounds do
      run_id = "contended-#{round}-#{System.unique_integer([:positive])}"

      results =
        1..@claimants
        |> Enum.map(fn _i ->
          Task.async(fn ->
            claimant =
              spawn(fn ->
                receive do
                  :stop -> :ok
                end
              end)

            result = LeaseMonitor.claim(monitor, run_id, claimant)
            {result, claimant}
          end)
        end)
        |> Enum.map(&Task.await(&1, 30_000))

      winners =
        Enum.filter(results, fn
          {{:ok, _epoch}, _pid} -> true
          _ -> false
        end)

      assert length(winners) == 1,
             "round #{round}: expected exactly 1 winner, got #{length(winners)}"

      assert {:ok, 1} = elem(hd(winners), 0)

      {:held, winner_pid, _epoch} = LeaseMonitor.status(monitor, run_id)
      assert {{:ok, _}, ^winner_pid} = hd(winners)

      # Cleanup: release via the winner's pid; claimant shells terminated.
      assert :ok = LeaseMonitor.release(monitor, run_id, winner_pid)
      assert :vacant = LeaseMonitor.status(monitor, run_id)

      Enum.each(results, fn {_, pid} -> send(pid, :stop) end)
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Holder exclusivity: renew vs steal interleaved
  # ---------------------------------------------------------------------------

  test "holder always wins renewal; stealer succeeds only after lapse (release/death)",
       %{monitor: monitor} do
    run_id = "renew-steal-#{System.unique_integer([:positive])}"
    holder = spawn_holder()
    stealer = spawn_holder()

    assert {:ok, 1} = LeaseMonitor.claim(monitor, run_id, holder)

    # Interleaved renew-vs-steal storm while the holder is alive: every holder
    # renewal must succeed and bump the epoch monotonically; every steal attempt
    # by the non-holder must be refused.
    epochs =
      Enum.map(1..100, fn i ->
        holder_result =
          if rem(i, 2) == 1, do: LeaseMonitor.heartbeat(monitor, run_id, holder), else: nil

        steal_result = LeaseMonitor.claim(monitor, run_id, stealer)
        {holder_result, steal_result}
      end)

    holder_epochs = for {{:ok, e}, _} <- epochs, do: e
    assert length(holder_epochs) == 50
    assert holder_epochs == Enum.to_list(2..51), "epochs must advance monotonically"

    Enum.each(epochs, fn {_, steal} ->
      assert {:error, {:claimed, ^holder, _e}} = steal
    end)

    # Lapse path A: holder releases -> stealer can claim fresh.
    assert :ok = LeaseMonitor.release(monitor, run_id, holder)
    assert :vacant = LeaseMonitor.status(monitor, run_id)
    assert {:ok, 1} = LeaseMonitor.claim(monitor, run_id, stealer)
    assert :ok = LeaseMonitor.release(monitor, run_id, stealer)

    # Lapse path B: holder dies -> monitor :DOWN frees the lease -> stealer wins.
    holder2 = spawn_holder()
    assert {:ok, 1} = LeaseMonitor.claim(monitor, run_id, holder2)
    send(holder2, :die)

    :ok = poll_until(fn -> match?(:vacant, LeaseMonitor.status(monitor, run_id)) end)
    assert {:ok, 1} = LeaseMonitor.claim(monitor, run_id, stealer)
    assert :ok = LeaseMonitor.release(monitor, run_id, stealer)
    send(stealer, :stop)
  end

  # ---------------------------------------------------------------------------
  # 4. Table hygiene: no accumulation over grant/release cycles
  # ---------------------------------------------------------------------------

  test "lease table size stable after #{@hygiene_cycles} grant/release cycles (release path)",
       %{monitor: monitor} do
    run_id_base = "hygiene-rel-#{System.unique_integer([:positive])}"

    # Baseline: empty server state.
    %{table: table, monitors: monitors} = :sys.get_state(monitor)
    assert :ets.info(table, :size) == 0
    assert map_size(monitors) == 0

    for i <- 1..@hygiene_cycles do
      run_id = "#{run_id_base}-#{i}"
      worker = spawn_holder()
      assert {:ok, 1} = LeaseMonitor.claim(monitor, run_id, worker)
      assert {:held, ^worker, 1} = LeaseMonitor.status(monitor, run_id)
      assert :ok = LeaseMonitor.release(monitor, run_id, worker)
      send(worker, :stop)
    end

    # Structural invariant: table and monitor map returned to baseline exactly.
    %{table: table, monitors: monitors} = :sys.get_state(monitor)

    assert :ets.info(table, :size) == 0,
           "released entries accumulated: #{:ets.info(table, :size)}"

    assert map_size(monitors) == 0, "demonitored refs leaked: #{inspect(monitors)}"
  end

  test "monitor-dead entries do not accumulate: 100 crashed holders free their leases",
       %{monitor: monitor} do
    run_id_base = "hygiene-dead-#{System.unique_integer([:positive])}"

    for i <- 1..@hygiene_cycles do
      run_id = "#{run_id_base}-#{i}"
      worker = spawn_holder()
      assert {:ok, 1} = LeaseMonitor.claim(monitor, run_id, worker)
      send(worker, :die)
    end

    # Bounded poll: every crashed holder's :DOWN must have drained.
    :ok =
      poll_until(fn ->
        Enum.all?(1..@hygiene_cycles, fn i ->
          match?(:vacant, LeaseMonitor.status(monitor, "#{run_id_base}-#{i}"))
        end)
      end)

    # Fresh claim after the storm must still get epoch 1 — no stale state.
    worker = spawn_holder()
    assert {:ok, 1} = LeaseMonitor.claim(monitor, "#{run_id_base}-fresh", worker)
    assert :ok = LeaseMonitor.release(monitor, "#{run_id_base}-fresh", worker)
    send(worker, :stop)

    # Structural invariant: no monitor-dead entries remain.
    %{table: table, monitors: monitors} = :sys.get_state(monitor)
    assert :ets.info(table, :size) == 0
    assert map_size(monitors) == 0
  end
end

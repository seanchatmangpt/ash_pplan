defmodule AshPPlan.Standing.CachedSingleFlightTest do
  @moduledoc """
  Court for the single-flight claim in `AshPPlan.Standing.Cached.get_or_compute/3`.

  Proves: concurrent cold-key fills deduplicate to at most a bounded number of
  computes (1 in the common case, small bound for timeout fallbacks), every
  racer sees a byte-identical result, and a racer killed mid-compute wedges
  nothing — losers fall back to a direct recompute after the flight timeout.
  No mocks: the spy counts real `fun` invocations through public API via an
  ETS counter, same pattern as `CachedAdversarialTest`.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Standing
  alias AshPPlan.Standing.Cached

  @head String.duplicate("a", 40)
  @base String.duplicate("b", 40)
  @table :ash_pplan_standing_receipt_cache
  @claims :ash_pplan_standing_receipt_cache_claims

  setup do
    Cached.clear()
    :ok
  end

  defp run(run_id \\ "r1") do
    n = 4
    tasks = for i <- 1..n, do: %{id: :"t#{i}", depends_on: (i == 1 && []) || [:"t#{i - 1}"]}

    events =
      for i <- 1..n do
        %AshPPlan.ProcessEvidence.Event{
          id: "run:#{run_id}/t#{i}",
          activity: "task_succeeded",
          timestamp: ~U[2026-10-01 00:00:00Z],
          objects: [{"WorkflowRun", "run:#{run_id}", "run"}],
          attributes: %{task: "t#{i}", seq: i, provider: "p#{i}", outcome: nil},
          subject_id: "subject-1"
        }
      end

    attempts = Map.new(1..n, fn i -> {:"t#{i}", 1} end)

    %{
      run_id: run_id,
      repo: "ash_pplan",
      head: @head,
      base: @base,
      events: events,
      model: %{tasks: tasks},
      selection: Map.new(1..n, fn i -> {"t#{i}", :"p#{i}"} end),
      fond_gates: [],
      execution: {attempts, attempts},
      consequence: [chain_complete: true],
      observation: %{tasks_completed: n}
    }
  end

  defp opts, do: [replay_commands: [%{cmd: "mix test", cwd: File.cwd!(), exit: 0}]]

  defp spawn_racers(key_run, counted_fun, n) do
    barrier = :ets.new(:sf_start_gate, [:public, :set])
    :ets.insert(barrier, {:go, false})
    parent = self()

    pids =
      for i <- 1..n do
        spawn_link(fn ->
          wait_for_gate(barrier)
          result = Cached.get_or_compute(key_run, opts(), counted_fun)
          send(parent, {:result, i, result})
        end)
      end

    :ets.insert(barrier, {:go, true})
    Enum.each(pids, fn pid -> send(pid, :recheck) end)
    {pids, parent}
  end

  defp collect_results(n) do
    for _ <- 1..n do
      receive do
        {:result, _i, r} -> r
      end
    end
  end

  defp wait_for_gate(barrier) do
    case :ets.lookup(barrier, :go) do
      [{:go, true}] ->
        :ok

      _ ->
        receive do
          :recheck -> :ok
        after
          50 -> :ok
        end

        wait_for_gate(barrier)
    end
  end

  test "single flight: 16 racers on a cold key deduplicate to 1 compute, byte-identical results" do
    key_run = run() |> put_in([Access.key!(:run_id)], "single-flight-1")
    key = Cached.identity(key_run, opts())

    spy = :ets.new(:sf_spy, [:public, :set])
    :ets.insert(spy, {:computes, 0})

    counted_fun = fn ->
      :ets.update_counter(spy, :computes, 1)
      Standing.receipt(key_run, opts())
    end

    {_pids, _parent} = spawn_racers(key_run, counted_fun, 16)
    results = collect_results(16)

    assert match?({:ok, %AshPPlan.Standing.Receipt{}}, hd(results))
    assert length(Enum.uniq(results)) == 1, "racers disagreed on the receipt"

    computes = :ets.lookup(spy, :computes) |> hd() |> elem(1)

    assert computes in 1..3,
           "expected <=3 computes under single-flight, got #{computes}"

    # the slot holds exactly one value and every caller saw it
    assert [{^key, {:ok, receipt}, _}] = :ets.lookup(@table, key)
    assert hd(results) == {:ok, receipt}

    # exactly one racer held the claim, and the claim is released on completion
    assert [] = :ets.lookup(@claims, key)

    IO.puts("[cached_single_flight] 16 racers cold fill: computes=#{computes} (bound <=3)")
  end

  test "warm key after single flight: 16 more racers produce 0 computes" do
    key_run = run() |> put_in([Access.key!(:run_id)], "single-flight-2")

    {:ok, first} = Standing.receipt_cached(key_run, opts())

    spy = :ets.new(:sf_spy2, [:public, :set])
    :ets.insert(spy, {:computes, 0})

    counted_fun = fn ->
      :ets.update_counter(spy, :computes, 1)
      Standing.receipt(key_run, opts())
    end

    {_pids, _parent} = spawn_racers(key_run, counted_fun, 16)
    results = collect_results(16)

    assert length(Enum.uniq(results)) == 1
    assert hd(results) == {:ok, first}

    computes = :ets.lookup(spy, :computes) |> hd() |> elem(1)
    assert computes == 0, "warm key recomputed #{computes} times"
  end

  test "crashed racer mid-compute does not wedge the key: losers fall back, results identical" do
    Application.put_env(:ash_pplan, :standing_flight_timeout_ms, 150)

    try do
      key_run = run() |> put_in([Access.key!(:run_id)], "single-flight-crash")
      key = Cached.identity(key_run, opts())

      spy = :ets.new(:sf_spy3, [:public, :set])
      :ets.insert(spy, {:computes, 0})
      gate = :ets.new(:sf_crash_gate, [:public, :set])
      :ets.insert(gate, {:go, false})

      doomed = fn ->
        :ets.update_counter(spy, :computes, 1)

        wait_for_gate(gate)
        # simulate a hard kill mid-compute: no after-clause runs, claim leaks
        exit(:simulated_crash)
      end

      parent = self()

      crasher =
        spawn(fn ->
          Cached.get_or_compute(key_run, opts(), doomed)
          send(parent, :crasher_returned)
        end)

      # wait until the doomed racer holds the claim, then release the gate
      wait_until(fn -> match?([{^key, _}], :ets.lookup(@claims, key)) end)
      :ets.insert(gate, {:go, true})
      send(crasher, :recheck)

      # racers arriving while the stale claim sits there must still get results
      counted_fun = fn ->
        :ets.update_counter(spy, :computes, 1)
        Standing.receipt(key_run, opts())
      end

      {_pids, _} = spawn_racers(key_run, counted_fun, 16)
      results = collect_results(16)

      assert match?({:ok, %AshPPlan.Standing.Receipt{}}, hd(results))
      assert length(Enum.uniq(results)) == 1

      computes = :ets.lookup(spy, :computes) |> hd() |> elem(1)
      assert computes in 2..3, "expected crasher + <=2 fallback computes, got #{computes}"

      # the key is not wedged: a fresh caller hits the cached value immediately
      assert {:ok, warm} = Standing.receipt_cached(key_run, opts())
      assert {:ok, ^warm} = Standing.receipt_cached(key_run, opts())
      assert [] = :ets.lookup(@claims, key), "stale claim was never cleaned"

      IO.puts(
        "[cached_single_flight] crash mid-compute: computes=#{computes}, no wedge, claim cleaned"
      )
    after
      Application.delete_env(:ash_pplan, :standing_flight_timeout_ms)
      Cached.clear()
    end
  end

  defp wait_until(fun, tries \\ 200)

  defp wait_until(_fun, 0), do: flunk("condition never became true")

  defp wait_until(fun, tries) do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      wait_until(fun, tries - 1)
    end
  end
end

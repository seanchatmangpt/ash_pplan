defmodule AshPPlan.Standing.ReceiptCachedTest do
  # non-async: the receipt cache is a single global ETS table shared across
  # tests; async exact-size assertions (size == max) flake when sibling tests
  # insert concurrently.
  use ExUnit.Case, async: false

  alias AshPPlan.Standing
  alias AshPPlan.Standing.Cached

  @head String.duplicate("a", 40)
  @base String.duplicate("b", 40)

  setup do
    Cached.clear()
    :ok
  end

  defp run(n \\ 4) do
    tasks = for i <- 1..n, do: %{id: :"t#{i}", depends_on: (i == 1 && []) || [:"t#{i - 1}"]}

    events =
      for i <- 1..n do
        %AshPPlan.ProcessEvidence.Event{
          id: "run:r1/t#{i}",
          activity: "task_succeeded",
          timestamp: ~U[2026-10-01 00:00:00Z],
          objects: [{"WorkflowRun", "run:r1", "run"}],
          attributes: %{task: "t#{i}", seq: i, provider: "p#{i}", outcome: nil},
          subject_id: "subject-1"
        }
      end

    attempts = Map.new(1..n, fn i -> {:"t#{i}", 1} end)

    %{
      run_id: "r1",
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

  test "determinism: same inputs give byte-identical receipts, cached or not" do
    run = run()
    {:ok, uncached} = Standing.receipt(run, opts())
    {:ok, first} = Standing.receipt_cached(run, opts())
    {:ok, second} = Standing.receipt_cached(run, opts())

    assert first == uncached
    assert second == uncached
  end

  test "invalidation: different events produce a different receipt via a different identity" do
    {:ok, a} = Standing.receipt_cached(run(4), opts())
    {:ok, b} = Standing.receipt_cached(run(5), opts())

    assert a.replay.ledger_digest != b.replay.ledger_digest
    assert a != b

    # the original key is untouched by the other key's insertions
    {:ok, a2} = Standing.receipt_cached(run(4), opts())
    assert a2 == a
  end

  test "bounded size: table never exceeds the LRU bound" do
    for i <- 1..(Cached.max_entries() + 10) do
      {:ok, _} = Standing.receipt_cached(run() |> put_in([Access.key!(:run_id)], "r#{i}"), opts())
    end

    assert Cached.size() <= Cached.max_entries()
  end

  test "LRU eviction drops the least recently used entry first" do
    max = Cached.max_entries()

    for i <- 1..max,
        do: Standing.receipt_cached(run() |> put_in([Access.key!(:run_id)], "r#{i}"), opts())

    # touch entry r1 so it becomes most recently used
    Standing.receipt_cached(run() |> put_in([Access.key!(:run_id)], "r1"), opts())

    # evict exactly one by inserting a new key
    Standing.receipt_cached(run() |> put_in([Access.key!(:run_id)], "r-new"), opts())

    assert Cached.size() == max
    identity = Cached.identity(run() |> put_in([Access.key!(:run_id)], "r1"), opts())

    assert [{_, {:ok, _receipt}, _}] =
             :ets.lookup(:ash_pplan_standing_receipt_cache, identity)
  end

  test "errors are cached: a malformed run refuses identically on hit" do
    bad = run() |> Map.drop([:run_id])
    {:error, first} = Standing.receipt_cached(bad, opts())
    {:error, second} = Standing.receipt_cached(bad, opts())
    assert first == second
  end

  test "concurrent safety: two processes on the same key get identical results" do
    run = run()

    parent = self()

    for _ <- 1..2 do
      spawn_link(fn ->
        result = Standing.receipt_cached(run, opts())
        send(parent, {:result, result})
      end)
    end

    results =
      for _ <- 1..2 do
        receive do
          {:result, r} -> r
        end
      end

    assert [a, b] = results
    assert a == b
    assert match?({:ok, _}, a)
  end
end

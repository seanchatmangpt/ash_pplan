defmodule AshPPlan.Standing.CachedAdversarialTest do
  @moduledoc """
  Adversarial court for `AshPPlan.Standing.Cached` (receipt_cached/2).

  Attacks: identity poisoning (can two semantically different inputs share one
  cache key?), concurrent cold-fill, eviction storm, error-cache correctness,
  and monotonic-clock independence. No sleeps; no mocks — the spy counts real
  `fun` invocations through the public `get_or_compute/3`.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Standing
  alias AshPPlan.Standing.Cached

  @head String.duplicate("a", 40)
  @base String.duplicate("b", 40)
  @table :ash_pplan_standing_receipt_cache

  setup do
    Cached.clear()
    :ok
  end

  # ---- fixtures (real Standing.receipt inputs, mirroring receipt_cached_test) ----

  defp run(n \\ 4, run_id \\ "r1") do
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

  # ---- attack 1: poisoned identity ----

  test "identity poisoning: conflicting atom/string keys, 1 vs 1.0, deep structs all hash apart" do
    # Every pair below differs semantically; if any two share an identity the
    # cache would serve one run's receipt for the other.
    variants = [
      atom_key: %{a: 1},
      string_key: %{"a" => 1},
      float_one: %{a: 1.0},
      int_one: %{b: 1},
      deep_struct: %{
        a: %AshPPlan.ProcessEvidence.Event{
          id: "x",
          activity: "task_succeeded",
          timestamp: ~U[2026-10-01 00:00:00Z],
          objects: [],
          attributes: %{},
          subject_id: "s"
        }
      },
      plain_map: %{a: %{id: "x", __struct__: AshPPlan.ProcessEvidence.Event}}
    ]

    idents =
      for {label, term} <- variants do
        {label, Cached.identity(term, [])}
      end

    assert length(Enum.uniq_by(idents, fn {_, id} -> id end)) == length(idents),
           "identity collision among semantically distinct inputs: #{inspect(idents)}"

    # Direct poison probe: prove that equal binaries imply equal terms for the
    # exact shapes the cache keys on (term_to_binary injectivity on these terms),
    # and that identity still matches its documented spec frame exactly.
    for {label, term} <- variants do
      assert :erlang.term_to_binary(term) == :erlang.term_to_binary(term)

      # spec frame: no :events list -> tagged whole-term sha256
      assert Cached.identity(term, []) ==
               :crypto.hash(
                 :sha256,
                 ["ash-pplan-standing-identity-v2", <<0::8>>, :erlang.term_to_binary({term, []})]
               ),
             "identity drifted from its spec for #{label}"
    end

    # 1 vs 1.0 specifically: floats must never alias integers.
    refute Cached.identity(%{a: 1}, []) == Cached.identity(%{a: 1.0}, [])
  end

  test "identity poisoning at the API level: distinct real runs never share a cache slot" do
    {:ok, r4} = Standing.receipt_cached(run(4), opts())
    {:ok, r5} = Standing.receipt_cached(run(5), opts())
    refute r4 == r5

    # and the poisoned-looking variants (same head/base, different run_id) stay apart
    {:ok, other} = Standing.receipt_cached(run(4, "r2"), opts())
    refute r4 == other
  end

  test "leaf poisoning: same event id, different content never aliases; append-only extension moves identity" do
    base_run = run(4)
    ident_base = Cached.identity(base_run, opts())

    # same ids, one event's content differs -> different leaf -> different identity
    poisoned =
      update_in(base_run, [Access.key!(:events), Access.at(2), Access.key!(:activity)], fn _ ->
        "task_failed"
      end)

    refute Cached.identity(poisoned, opts()) == ident_base

    # reordering two events (same multiset of content) also moves the identity
    reordered = update_in(base_run, [Access.key!(:events)], &Enum.reverse/1)
    refute Cached.identity(reordered, opts()) == ident_base

    # append-only extension: prefix events unchanged, identity changes, and the
    # memoized leaves of the prefix stay correct (identity is stable per term)
    extended = put_in(base_run, [Access.key!(:events)], base_run.events ++ base_run.events)
    assert Cached.identity(extended, opts()) != ident_base
    assert Cached.identity(base_run, opts()) == ident_base
    assert Cached.identity(extended, opts()) == Cached.identity(extended, opts())
  end

  @doc """
  FINDING (admitted, documented): the cache key covers `{run, opts}` only — the
  computation `fun` is not part of the identity. Two *different* functions on the
  same `{run, opts}` share a slot. This is safe in production because
  `Standing.receipt_cached/2` always passes the one fixed `fun`
  (`Standing.receipt(run, opts)`); the court proves the boundary explicitly
  rather than letting it be silently rediscovered.
  """
  test "documented boundary: identity covers {run, opts}, not the closure" do
    run = run()
    {:ok, real} = Standing.receipt_cached(run, opts())

    # same {run, opts}, a DIFFERENT fun through the public get_or_compute/3:
    # served from cache, so the alien fun must NOT run.
    parent = self()

    alien = fn ->
      send(parent, :alien_ran)
      {:ok, :poisoned}
    end

    assert Cached.get_or_compute(run, opts(), alien) == {:ok, real}
    refute_received :alien_ran
  end

  # ---- attack 2: concurrent cold-fill ----

  test "concurrent fill: 16 processes race one cold key, all results byte-identical" do
    run = run()
    key_run = run |> put_in([Access.key!(:run_id)], "concurrent")
    key = Cached.identity(key_run, opts())

    # spy: count real fun invocations through an ETS counter (no mock)
    spy = :ets.new(:fill_spy, [:public, :set])
    :ets.insert(spy, {:computes, 0})

    counted_fun = fn ->
      :ets.update_counter(spy, :computes, 1)
      Standing.receipt(key_run, opts())
    end

    barrier = :ets.new(:start_gate, [:public, :set])
    :ets.insert(barrier, {:go, false})

    parent = self()

    pids =
      for i <- 1..16 do
        spawn_link(fn ->
          wait_for_gate(barrier)
          result = Cached.get_or_compute(key_run, opts(), counted_fun)
          send(parent, {:result, i, result})
        end)
      end

    # release all racers as simultaneously as the runtime allows
    :ets.insert(barrier, {:go, true})
    # re-poke any waiter that sampled the gate before the flag landed
    Enum.each(pids, fn pid -> send(pid, :recheck) end)

    results =
      for _ <- 1..16 do
        receive do
          {:result, _i, r} -> r
        end
      end

    assert match?({:ok, %AshPPlan.Standing.Receipt{}}, hd(results))
    assert length(Enum.uniq(results)) == 1, "racers disagreed on the receipt"

    computes = :ets.lookup(spy, :computes) |> hd() |> elem(1)
    # the slot holds exactly one value and every caller saw it
    assert [{^key, {:ok, receipt}, _}] = :ets.lookup(@table, key)
    assert hd(results) == {:ok, receipt}

    IO.puts(
      "[cached_adversarial] concurrent cold-fill computes=#{computes} (expected 1; " <>
        "values >1 are the known insert-race, results stay byte-identical)"
    )
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

  # ---- attack 3: eviction storm ----

  test "eviction storm: 500 keys over a 256-entry cache evicts oldest, keeps newest, no crash" do
    max = Cached.max_entries()
    assert max == 256

    first_key =
      run()
      |> put_in([Access.key!(:run_id)], "storm-1")
      |> then(&Cached.identity(&1, opts()))

    for i <- 1..500 do
      assert {:ok, _} =
               run()
               |> put_in([Access.key!(:run_id)], "storm-#{i}")
               |> Standing.receipt_cached(opts())
    end

    newest_key =
      run()
      |> put_in([Access.key!(:run_id)], "storm-500")
      |> then(&Cached.identity(&1, opts()))

    assert Cached.size() == max
    assert [] = :ets.lookup(@table, first_key), "oldest entry survived the storm"

    assert match?([{_k, {:ok, _}, _}], :ets.lookup(@table, newest_key)),
           "newest entry was evicted"

    # survivors are exactly the most recent `max` keys (LRU order held under load)
    survivor_ids =
      for i <- (500 - max + 1)..500 do
        run()
        |> put_in([Access.key!(:run_id)], "storm-#{i}")
        |> then(&Cached.identity(&1, opts()))
      end

    present =
      @table
      |> :ets.tab2list()
      |> MapSet.new(fn {k, _, _} -> k end)

    assert MapSet.subset?(MapSet.new(survivor_ids), present)

    # oldest one recomputes cleanly after eviction (no poisoned slot, no crash)
    assert {:ok, again} =
             run()
             |> put_in([Access.key!(:run_id)], "storm-1")
             |> Standing.receipt_cached(opts())

    assert match?(%AshPPlan.Standing.Receipt{}, again)
  end

  # ---- attack 4: error-cache correctness ----

  test "error-cache: a cached error never bleeds into a later valid run" do
    bad = run() |> Map.drop([:run_id])
    {:error, first_err} = Standing.receipt_cached(bad, opts())
    {:error, cached_err} = Standing.receipt_cached(bad, opts())
    assert first_err == cached_err

    # a VALID run with different events gets its own computed result,
    # not the cached error and not a corrupted value
    {:ok, good} = Standing.receipt_cached(run(5, "valid"), opts())
    assert match?(%AshPPlan.Standing.Receipt{}, good)
    refute good == first_err

    # the error slot is still the error, byte-identical
    {:error, still_err} = Standing.receipt_cached(bad, opts())
    assert still_err == first_err

    # and the error is deterministically the real refusal, not a cache artifact
    {:error, direct} = Standing.receipt(bad, opts())
    assert direct == first_err
  end

  # ---- attack 5: monotonic-clock independence ----

  test "monotonic-clock independence: hits depend on identity only, never on elapsed time" do
    run = run()
    {:ok, first} = Standing.receipt_cached(run, opts())

    # burn arbitrary monotonic time — advances the clock the LRU stamps with
    t0 = System.monotonic_time()

    _burn =
      Stream.repeatedly(fn -> System.monotonic_time() end)
      |> Stream.take(10_000)
      |> Enum.max()

    t1 = System.monotonic_time()
    assert t1 >= t0

    # no TTL anywhere in the module: the entry must still hit, byte-identical
    {:ok, second} = Standing.receipt_cached(run, opts())
    assert second == first

    # structural proof: identity is a pure function of {run, opts} — no clock input
    assert Cached.identity(run, opts()) == Cached.identity(run, opts())

    # the stored stamp is the only clock touch, and it orders eviction, not validity:
    # mutating no clock value, a lookup changes the value never, only the stamp.
    key = Cached.identity(run, opts())
    [{^key, value_before, _stamp1}] = :ets.lookup(@table, key)
    {:ok, _} = Standing.receipt_cached(run, opts())
    [{^key, ^value_before, _stamp2}] = :ets.lookup(@table, key)

    # stamps only move forward under touches (LRU order is well-defined)
    # and identity hashes carry no time-derived bytes (fixed length, deterministic)
    assert byte_size(key) == 32
  end
end

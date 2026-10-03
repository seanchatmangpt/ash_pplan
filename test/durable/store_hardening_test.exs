defmodule AshPPlan.Reactor.Durable.StoreHardening do
  @moduledoc """
  Hardening laws shared by every `AshPPlan.Reactor.Durable.Store` implementation. Not part of the
  generated `AshPPlan.Test.StoreConformance` suite (that file is ggen-generated); these laws cover
  storm/race/crash surfaces the generated laws leave open. Hand-written per the Chicago discipline:
  every assertion lands on real store state.
  """

  alias AshPPlan.Reactor.Durable.Store.Dets
  alias AshPPlan.Reactor.Durable.Store.Ets

  @t0 ~U[2026-01-01 00:00:00.000Z]

  @doc "Store implementations under test: {tag, start} pairs, `start` returning {:ok, store}."
  def stores do
    [
      ets: fn -> Ets.start_link() end,
      dets: fn -> Dets.start_link(path: tmp_path()) end
    ]
  end

  def tmp_path do
    Path.join(
      System.tmp_dir!(),
      "ash_pplan_hard_#{System.unique_integer([:positive])}_#{:erlang.phash2(make_ref())}.dets"
    )
  end

  def t0, do: @t0

  @doc """
  Storm: 24 concurrent tasks mix claim/transition/record/park/release/deliver/consume against one
  store. Invariants: exactly one claim winner, one standing checkpoint per key, unique signal ids,
  no caller ever sees a crash.
  """
  def law_mixed_op_storm(mod, s) do
    import ExUnit.Assertions

    {:ok, _} = mod.transition(s, "r1", [:pending], :polling, %{})

    results =
      1..24
      |> Task.async_stream(
        fn n ->
          claim =
            case mod.claim(s, "r1", {:c, n}, 60_000, @t0) do
              {:ok, _} -> :claim_win
              :taken -> :claim_taken
            end

          rec =
            case mod.record(s, "r1", "k#{rem(n, 6)}", "l", n, %{}) do
              {:ok, cp} -> {:ok, cp.output}
              other -> other
            end

          sig =
            case mod.deliver_signal(s, "r1", "go#{n}", n) do
              {:ok, sig} -> sig
              other -> flunk("deliver_signal returned #{inspect(other)}")
            end

          consume = mod.consume_signal(s, sig.id, @t0)

          park =
            case mod.park(s, "r1", "w#{rem(n, 4)}", :signal, nil, []) do
              {:ok, _} -> :parked
              other -> other
            end

          :ok = mod.release(s, "r1", "w#{rem(n, 4)}")
          {:ok, _} = mod.transition(s, "r1", :any, :polling, %{n: n})
          {claim, rec, consume, park}
        end,
        max_concurrency: 24,
        timeout: 30_000
      )
      |> Enum.map(fn
        {:ok, r} -> r
        {:exit, reason} -> flunk("storm task crashed: #{inspect(reason)}")
      end)

    assert Enum.count(results, &match?({:claim_win, _, _, _}, &1)) == 1
    assert Enum.all?(results, &match?({_, {:ok, _}, _, :parked}, &1))

    # one standing checkpoint per key, in seq order
    standing = mod.standing(s, "r1")
    assert length(standing) == 6
    assert standing == Enum.sort_by(standing, & &1.seq)

    sigs = mod.signals(s, "r1")
    assert length(sigs) == 24
    assert length(Enum.uniq(Enum.map(sigs, & &1.id))) == 24

    assert mod.get_run(s, "r1").status == :polling
  end

  @doc "Counter/seq race: concurrent deliver_signal/record calls draw from one seq counter without collisions."
  def law_seq_uniqueness_storm(mod, s) do
    import ExUnit.Assertions

    sigs =
      1..64
      |> Task.async_stream(fn n -> mod.deliver_signal(s, "r1", "s#{n}", n) end,
        max_concurrency: 64,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, {:ok, sig}} -> sig end)

    assert length(Enum.uniq(Enum.map(sigs, & &1.id))) == 64
    assert length(Enum.uniq(Enum.map(sigs, & &1.seq))) == 64

    cps =
      1..32
      |> Task.async_stream(fn n -> mod.record(s, "r1", "ck#{n}", "l", n, %{}) end,
        max_concurrency: 32,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, {:ok, cp}} -> cp end)

    assert length(cps) == 32
    assert length(Enum.uniq(Enum.map(cps, & &1.seq))) == 32

    # signals and checkpoints share one seq space: no collisions across kinds
    all = Enum.map(sigs, & &1.seq) ++ Enum.map(cps, & &1.seq)
    assert length(Enum.uniq(all)) == 96
  end
end

defmodule AshPPlan.Reactor.Durable.StoreHardeningBothTest do
  @moduledoc """
  Parametrized court: every hardening law runs against BOTH `Store.Ets` and `Store.Dets` —
  the same assertions, same seed data, so a semantic divergence between the two implementations
  fails one side only.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Reactor.Durable.Store.Dets
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Reactor.Durable.StoreHardening, as: H

  for tag <- Keyword.keys(H.stores()) do
    describe "#{tag}" do
      test "mixed_op_storm" do
        s = boot(unquote(tag))

        try do
          H.law_mixed_op_storm(impl(unquote(tag)), s)
        after
          stop(s)
        end
      end

      test "seq_uniqueness_storm" do
        s = boot(unquote(tag))

        try do
          H.law_seq_uniqueness_storm(impl(unquote(tag)), s)
        after
          stop(s)
        end
      end
    end
  end

  defp start(:ets), do: Ets.start_link()
  defp start(:dets), do: Dets.start_link(path: H.tmp_path())

  defp impl(:ets), do: Ets
  defp impl(:dets), do: Dets

  defp boot(tag) do
    {:ok, s} = start(tag)
    {:ok, _} = impl(tag).start_run(s, %{id: "r1", model: :m, bindings: %{}})
    s
  end

  defp stop(s) do
    if is_pid(s) and Process.alive?(s), do: GenServer.stop(s, :normal)
  end
end

defmodule AshPPlan.Reactor.Durable.StoreDetsCrashHardeningTest do
  @moduledoc """
  DETS-only crash and open-concurrency hardening: kill the store process outright (no terminate,
  no final sync) and reopen the same path; a second concurrent open of the same path is refused
  with `{:error, {:path_in_use, path}}` instead of DETS's silent double-open.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Reactor.Durable.Store.Dets
  alias AshPPlan.Reactor.Durable.StoreHardening, as: H

  setup do
    # a failed start_link exits its child non-normally; trap so the assert on the error
    # tuple decides the outcome instead of a poisoned link
    Process.flag(:trap_exit, true)
    :ok
  end

  test "reopen after unclean kill preserves every acknowledged write and the sequence" do
    path = H.tmp_path()
    on_exit(fn -> File.rm(path) end)
    {:ok, s} = Dets.start_link(path: path)
    t0 = H.t0()

    {:ok, _} = Dets.start_run(s, %{id: "r1", model: :m, bindings: %{a: 1}})
    {:ok, cp} = Dets.record(s, "r1", "k1", "one", 1, %{})
    {:ok, w} = Dets.park(s, "r1", "w", :signal, t0, [])
    {:ok, sig1} = Dets.deliver_signal(s, "r1", "go", 1)
    {:ok, _} = Dets.claim(s, "r1", :a, 60_000, t0)
    max_seq = sig1.seq

    # unclean death: terminate/2 never runs, no final sync
    Process.unlink(s)
    ref = Process.monitor(s)
    Process.exit(s, :kill)
    assert_receive {:DOWN, ^ref, :process, ^s, :killed}

    {:ok, s2} = Dets.start_link(path: path)

    assert %AshPPlan.Reactor.Durable.Record{bindings: %{a: 1}, claimed_by: :a} =
             Dets.get_run(s2, "r1")

    assert %AshPPlan.Reactor.Durable.Checkpoint{output: 1} = Dets.checkpoints(s2, "r1")["k1"]
    assert Dets.get_waiter(s2, "r1", "w").deadline == t0
    assert Dets.pending_signal(s2, "r1", "go").id == sig1.id

    # the persisted seq survived: new writes never reuse a pre-kill id
    {:ok, sig2} = Dets.deliver_signal(s2, "r1", "go", 2)
    assert sig2.seq > max_seq and sig2.id > max_seq

    # undo machinery works on the reopened row; the waiter is intact
    assert {:ok, _} = Dets.claim_undo(s2, "r1", "k1", t0)
    assert Dets.standing(s2, "r1") == []
    assert :ok = Dets.release_undo(s2, "r1", "k1")
    assert Enum.map(Dets.standing(s2, "r1"), & &1.step_key) == ["k1"]
    assert Dets.get_waiter(s2, "r1", "w") != nil
    _ = {cp, w}
  end

  test "second concurrent open of the same path is refused, not silently double-opened" do
    path = H.tmp_path()
    on_exit(fn -> File.rm(path) end)
    {:ok, s} = Dets.start_link(path: path)

    assert {:error, {:path_in_use, _}} = Dets.start_link(path: path)
    # the same path via a differently-expressed form is the same lock slot
    assert {:error, {:path_in_use, _}} = Dets.start_link(path: String.to_charlist(path))
    # the first store keeps working
    {:ok, _} = Dets.start_run(s, %{id: "r1", model: :m, bindings: %{}})

    GenServer.stop(s, :normal)

    # after a clean stop the path is free again
    {:ok, s2} = Dets.start_link(path: path)
    {:ok, _} = Dets.start_run(s2, %{id: "r2", model: :m, bindings: %{}})
    GenServer.stop(s2, :normal)
  end

  test "a killed owner's lock is taken over by a reopen of the same path" do
    path = H.tmp_path()
    on_exit(fn -> File.rm(path) end)
    {:ok, s} = Dets.start_link(path: path)
    {:ok, _} = Dets.start_run(s, %{id: "r1", model: :m, bindings: %{}})

    Process.unlink(s)
    ref = Process.monitor(s)
    Process.exit(s, :kill)
    assert_receive {:DOWN, ^ref, :process, ^s, :killed}

    {:ok, s2} = Dets.start_link(path: path)
    assert Dets.get_run(s2, "r1").id == "r1"
    GenServer.stop(s2, :normal)
  end
end

defmodule AshPPlan.Reactor.Durable.StoreDetsTest do
  @moduledoc """
  Court for `Store.Dets` persistence: state written through one store process survives stopping
  it (and killing it) and starting a new store on the same file. Complements the generated
  conformance suite (`store_conformance_dets_test.exs`), which proves the callback laws.
  Anti-vacuity mutation: a fresh store on a different path must see none of this state, so a
  store that ignored its file (pure in-memory) would fail the "intact" assertions.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Reactor.Durable.Store.Dets

  @t0 ~U[2026-01-01 00:00:00.000Z]

  setup do
    path =
      Path.join(System.tmp_dir!(), "ash_pplan_dets_#{System.unique_integer([:positive])}.dets")

    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  defp populate(s) do
    {:ok, _} = Dets.start_run(s, %{id: "r1", model: :m, bindings: %{a: 1}})
    {:ok, _} = Dets.start_run(s, %{id: "r2", parent: {"r1", "sig"}})
    {:ok, _} = Dets.transition(s, "r1", [:pending], :waiting, %{})
    {:ok, _} = Dets.claim(s, "r1", :worker, 60_000, @t0)
    {:ok, _} = Dets.record(s, "r1", "k1", "one", %{x: 1}, %{impl: Foo, args: %{y: 2}})
    {:ok, _} = Dets.record(s, "r1", "k2", "two", 2, %{})
    {:ok, _} = Dets.claim_undo(s, "r1", "k2", @t0)
    {:ok, g1} = Dets.deliver_signal(s, "r1", "go", :first)
    {:ok, _} = Dets.deliver_signal(s, "r1", "go", :second)
    {:ok, _} = Dets.consume_signal(s, g1.id, @t0)
    {:ok, _} = Dets.park(s, "r1", "w", :poll, DateTime.add(@t0, 1000, :millisecond), [])
    :ok
  end

  defp assert_intact(s) do
    assert Enum.map(Dets.list_runs(s), & &1.id) == ["r1", "r2"]
    r1 = Dets.get_run(s, "r1")
    assert r1.status == :waiting and r1.bindings == %{a: 1} and r1.model == :m
    assert r1.claimed_by == :worker and r1.version == 3
    assert Dets.get_run(s, "r2").parent_id == "r1"

    assert Enum.map(Dets.standing(s, "r1"), & &1.label) == ["one"]
    assert %{"k1" => k1, "k2" => k2} = Dets.checkpoints(s, "r1")
    assert k1.impl == Foo and k1.args == %{y: 2} and k1.output == %{x: 1}
    assert k2.undone_at == @t0
    assert :taken = Dets.claim_undo(s, "r1", "k2", @t0)

    assert [%{payload: :first, consumed_at: @t0}, %{payload: :second, consumed_at: nil}] =
             Dets.signals(s, "r1")

    assert Dets.pending_signal(s, "r1", "go").payload == :second
    assert Dets.get_waiter(s, "r1", "w").deadline == DateTime.add(@t0, 1000, :millisecond)

    # the lease survived: a different claimer inside it is refused, after it succeeds
    assert :taken = Dets.claim(s, "r1", :other, 60_000, DateTime.add(@t0, 1000, :millisecond))
    assert {:ok, _} = Dets.claim(s, "r1", :other, 60_000, DateTime.add(@t0, 61_000, :millisecond))
  end

  test "state survives stopping the store process and starting a new one on the same file",
       %{path: path} do
    {:ok, s1} = Dets.start_link(path: path)
    populate(s1)
    ref = Process.monitor(s1)
    GenServer.stop(s1)
    assert_receive {:DOWN, ^ref, :process, ^s1, _}

    {:ok, s2} = Dets.start_link(path: path)
    assert_intact(s2)
  end

  test "sequence counter continues after restart: new rows sort after old ones", %{path: path} do
    {:ok, s1} = Dets.start_link(path: path)
    {:ok, a} = Dets.start_run(s1, %{id: "a"})
    {:ok, cp1} = Dets.record(s1, "a", "k", "l", 1, %{})
    GenServer.stop(s1)

    {:ok, s2} = Dets.start_link(path: path)
    {:ok, b} = Dets.start_run(s2, %{id: "b"})
    {:ok, cp2} = Dets.record(s2, "a", "k2", "l2", 2, %{})
    assert b.seq > a.seq and cp2.seq > cp1.seq
    assert Enum.map(Dets.list_runs(s2), & &1.id) == ["a", "b"]
  end

  test "a different path is a different store (the file is the state)", %{path: path} do
    {:ok, s1} = Dets.start_link(path: path)
    populate(s1)
    GenServer.stop(s1)

    {:ok, other} = Dets.start_link(path: path <> ".other")
    on_exit(fn -> File.rm(path <> ".other") end)
    assert Dets.list_runs(other) == []
    assert Dets.checkpoints(other, "r1") == %{}
  end

  test "state survives killing the store process (every write is synced)", %{path: path} do
    Process.flag(:trap_exit, true)
    {:ok, s1} = Dets.start_link(path: path)
    populate(s1)
    ref = Process.monitor(s1)
    Process.exit(s1, :kill)
    assert_receive {:DOWN, ^ref, :process, ^s1, :killed}

    s2 = start_with_retry(path, 50)
    assert_intact(s2)
  end

  test "start_link requires :path" do
    assert_raise KeyError, fn -> Dets.start_link([]) end
  end

  defp start_with_retry(path, 0), do: elem(Dets.start_link(path: path), 1)

  defp start_with_retry(path, n) do
    Process.flag(:trap_exit, true)

    case Dets.start_link(path: path) do
      {:ok, pid} ->
        pid

      _ ->
        Process.sleep(20)
        start_with_retry(path, n - 1)
    end
  end
end

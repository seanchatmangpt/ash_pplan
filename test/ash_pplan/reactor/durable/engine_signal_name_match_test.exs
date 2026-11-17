defmodule AshPPlan.Reactor.Durable.EngineSignalNameMatchTest do
  @moduledoc """
  Court (fnox v26.11.16 R04, repairs S02-M5): `Engine.runnable?/4` wakes a parked run on a
  signal only when an UNCONSUMED signal carries the name of one of the run's parked `:signal`
  waiters. Two runs park on different waiter names; one signal is delivered to each with the
  SAME name — only the run whose waiter carries that name becomes runnable. The non-matching
  signal is never dropped: it stays stored unconsumed and wakes a later waiter of its name.

  A parked run with no `:signal` waiter at all is name-agnostic (nothing to match against), so
  any unconsumed signal wakes it — the pre-existing `wake/3` honesty court relies on this.

  Real collaborators only: real `Store.Wal` on a tmp file (rows written through the store API,
  no Reactor needed to exercise the level-triggered law), the test `Clock`, real restart via
  close/reopen. No `Process.sleep`.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.{Clock, Engine, Waiter}
  alias AshPPlan.Reactor.Durable.Store.Wal

  @wal [store_module: Wal]

  setup do
    Clock.use_test_clock(~U[2026-11-16 10:00:00Z])
    on_exit(&Clock.reset/0)

    path =
      Path.join(
        System.tmp_dir!(),
        "engine_signal_name_match_#{System.unique_integer([:positive])}.wal"
      )

    {:ok, wal} = Wal.open(path)
    holder = :"wal_holder_nm_#{System.unique_integer([:positive])}"
    {:ok, holder_pid} = Agent.start(fn -> wal end, name: holder)

    on_exit(fn ->
      if Process.alive?(holder_pid) do
        try do
          holder_pid |> Agent.get(& &1) |> safe_close()
        catch
          :exit, _ -> :ok
        end

        try do
          Agent.stop(holder_pid)
        catch
          :exit, _ -> :ok
        end
      end

      File.rm(path)
    end)

    %{wal: wal, path: path, holder: holder}
  end

  defp safe_close(%Wal{} = wal) do
    Wal.close(wal)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # A parked run as rows: started, moved to :waiting, one `:signal` waiter named `name`.
  defp park!(wal, id, name) do
    {:ok, _} = Wal.start_run(wal, %{id: id})
    {:ok, _} = Wal.transition(wal, id, [:pending], :waiting, %{})
    {:ok, %Waiter{kind: :signal, name: ^name}} = Wal.park(wal, id, name, :signal, nil, [])
    refute Engine.runnable?(wal, Wal.get_run(wal, id), Clock.now(), @wal)
    :ok
  end

  test "one signal name wakes only the run whose waiter carries that name; the other signal stays stored",
       %{wal: wal, path: path, holder: holder} do
    a = "run-a-#{System.unique_integer([:positive])}"
    b = "run-b-#{System.unique_integer([:positive])}"
    :ok = park!(wal, a, "alpha")
    :ok = park!(wal, b, "beta")
    assert Engine.runnable(wal, Clock.now(), @wal) == []

    # The same signal name delivered to both parked runs: it matches b's waiter, not a's.
    assert {:ok, %{name: "beta"}} = Engine.signal(wal, a, "beta", %{n: 1}, @wal)
    assert {:ok, %{name: "beta"}} = Engine.signal(wal, b, "beta", %{n: 2}, @wal)

    refute Engine.runnable?(wal, Wal.get_run(wal, a), Clock.now(), @wal)
    assert Engine.runnable?(wal, Wal.get_run(wal, b), Clock.now(), @wal)
    assert Engine.runnable(wal, Clock.now(), @wal) == [b]

    # wake/3 moves only the matching run's label.
    assert :ok = Engine.wake(wal, a, @wal)
    assert :ok = Engine.wake(wal, b, @wal)
    assert Wal.get_run(wal, a).status == :waiting
    assert Wal.get_run(wal, b).status == :pending

    # The non-matching signal is stored, unconsumed — not dropped.
    assert [%{name: "beta", consumed_at: nil}] = Wal.signals(wal, a)
    assert [%Waiter{name: "alpha", kind: :signal}] = Wal.waiters(wal, a)

    # The law reads rows: it survives a real restart.
    :ok = Wal.close(wal)
    assert {:ok, %Wal{} = wal2} = Wal.open(path)
    Agent.update(holder, fn _ -> wal2 end)

    refute Engine.runnable?(wal2, Wal.get_run(wal2, a), Clock.now(), @wal)
    assert [%{name: "beta", consumed_at: nil}] = Wal.signals(wal2, a)
    assert [%Waiter{name: "alpha"}] = Wal.waiters(wal2, a)

    # The matching name delivered later wakes a; the stored "beta" signal is still there for
    # a future "beta" waiter of run a.
    assert {:ok, %{name: "alpha"}} = Engine.signal(wal2, a, "alpha", %{n: 3}, @wal)
    assert Engine.runnable?(wal2, Wal.get_run(wal2, a), Clock.now(), @wal)
    assert a in Engine.runnable(wal2, Clock.now(), @wal)
    assert Enum.sort(Enum.map(Wal.signals(wal2, a), & &1.name)) == ["alpha", "beta"]
    assert Enum.all?(Wal.signals(wal2, a), &is_nil(&1.consumed_at))

    # Consuming the matching signal (what Steps.Await.take/5 does) makes a quiet again even
    # though the stray "beta" row is still unconsumed: no spin on a stray signal.
    %{id: sig_id} = Wal.pending_signal(wal2, a, "alpha")
    :ok = consume(wal2, sig_id)
    :ok = Wal.release(wal2, a, "alpha")

    assert [%{name: "beta", consumed_at: nil}] =
             Enum.filter(Wal.signals(wal2, a), &is_nil(&1.consumed_at))

    # No :signal waiter left on a -> name-agnostic: the stray unconsumed row is now a wake.
    assert Wal.waiters(wal2, a) == []
    assert Engine.runnable?(wal2, Wal.get_run(wal2, a), Clock.now(), @wal)
  end

  test "a run parked with two :signal waiters wakes on either name, never on a third",
       %{wal: wal} do
    id = "run-two-#{System.unique_integer([:positive])}"
    {:ok, _} = Wal.start_run(wal, %{id: id})
    {:ok, _} = Wal.transition(wal, id, [:pending], :waiting, %{})
    {:ok, _} = Wal.park(wal, id, "left", :signal, nil, [])
    {:ok, _} = Wal.park(wal, id, "right", :signal, nil, [])
    refute Engine.runnable?(wal, Wal.get_run(wal, id), Clock.now(), @wal)

    assert {:ok, _} = Engine.signal(wal, id, "third", :noise, @wal)
    refute Engine.runnable?(wal, Wal.get_run(wal, id), Clock.now(), @wal)
    assert Engine.runnable(wal, Clock.now(), @wal) == []

    assert {:ok, _} = Engine.signal(wal, id, "right", :go, @wal)
    assert Engine.runnable?(wal, Wal.get_run(wal, id), Clock.now(), @wal)
    assert Engine.runnable(wal, Clock.now(), @wal) == [id]

    # Both rows stand; only "third" is the stray.
    names = wal |> Wal.signals(id) |> Enum.filter(&is_nil(&1.consumed_at)) |> Enum.map(& &1.name)
    assert Enum.sort(names) == ["right", "third"]
  end

  test "a parked run with no :signal waiter is name-agnostic: any unconsumed signal wakes it",
       %{wal: wal} do
    id = "run-bare-#{System.unique_integer([:positive])}"
    {:ok, _} = Wal.start_run(wal, %{id: id})
    {:ok, _} = Wal.transition(wal, id, [:pending], :waiting, %{})
    assert Wal.waiters(wal, id) == []
    refute Engine.runnable?(wal, Wal.get_run(wal, id), Clock.now(), @wal)

    assert {:ok, _} = Engine.signal(wal, id, "anything", 1, @wal)
    assert Engine.runnable?(wal, Wal.get_run(wal, id), Clock.now(), @wal)
    assert :ok = Engine.wake(wal, id, @wal)
    assert Wal.get_run(wal, id).status == :pending
  end

  # Wal.consume_signal/3 is the store's consume primitive; its return shape is the store's,
  # so only completion is asserted here (the consumed row is re-read from the store above).
  defp consume(wal, sig_id) do
    _ = Wal.consume_signal(wal, sig_id, Clock.now())
    :ok
  end
end

defmodule AshPPlan.Reactor.Durable.UnwindCrashTest do
  @moduledoc """
  Court (P1 unwind crash window): `Store.claim_undo/4` takes a volatile leased claim (server
  state, never persisted) and `mark_undone/4` writes `undone_at` after the undo effect.
  Proven with real kill-injection over the real `Store.Ets` and `Store.Dets`: a rollback process
  killed between claim and effect must NOT leave a premature `undone_at` behind; the checkpoint
  stands again once the volatile claim lapses (or the store restarts) and the undo re-runs.

  Anti-vacuity: reverting `claim_undo` to write `undone_at` at claim time flips the
  no-premature-`undone_at` assertions; widening the undo-claim lease to infinity wedges the
  expiry test.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.{Clock, Key, Store.Dets, Store.Ets, Unwind}
  alias AshPPlan.Test.Effects

  @id_key AshPPlan.Reactor.context_key()
  @log :unwind_crash_court_log

  defmodule BlockingUndoStep do
    @moduledoc false
    use Reactor.Step

    @impl true
    def run(_a, _c, _o), do: {:ok, :done}

    @impl true
    def undo(_value, _args, _context, opts) do
      log = Keyword.fetch!(opts, :log)
      Effects.record(log, {:undo_started, Keyword.fetch!(opts, :effect)})

      receive do
        :go -> :ok
      after
        :infinity -> :ok
      end
    end
  end

  setup do
    {:ok, _} = Effects.start_link(name: @log)
    {:ok, store} = Ets.start_link([])
    Clock.use_test_clock()
    on_exit(fn ->
      if Process.alive?(@log), do: Agent.stop(@log)
      Clock.reset()
    end)

    {:ok, store: store}
  end

  defp stand(store, id, name, impl \\ {BlockingUndoStep, [log: @log, effect: name]}) do
    {:ok, cp} =
      Ets.record(store, id, Key.for_name(name), Key.label(name), {:out, name}, %{
        impl: impl,
        args: %{who: name}
      })

    cp
  end

  defp identity_context do
    %{@id_key => %{subject: "sha256:court", workflow: :court}}
  end

  defp wait_until(fun, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(10)
        wait_until(fun, deadline)

      true ->
        flunk("condition never held within budget")
    end
  end

  test "a rollback killed between claim_undo and the effect writes no premature undone_at", %{
    store: s
  } do
    id = "r1"
    {:ok, _} = Ets.start_run(s, %{id: id, context: identity_context()})
    stand(s, id, :a)

    victim = spawn(fn -> Unwind.run(s, id) end)

    wait_until(fn -> Effects.count(@log, {:undo_started, :a}) == 1 end)
    Process.exit(victim, :kill)
    wait_until(fn -> not Process.alive?(victim) end)

    [cp] = Ets.checkpoints(s, id) |> Map.values()
    assert cp.undone_at == nil
    assert Ets.standing(s, id) |> Enum.map(& &1.step_key) == [Key.for_name(:a)]
  end

  test "the volatile undo claim blocks a concurrent rollback until its lease lapses", %{
    store: s
  } do
    id = "r1"
    {:ok, _} = Ets.start_run(s, %{id: id, context: identity_context()})
    stand(s, id, :a)

    victim = spawn(fn -> Unwind.run(s, id) end)
    wait_until(fn -> Effects.count(@log, {:undo_started, :a}) == 1 end)
    Process.exit(victim, :kill)
    wait_until(fn -> not Process.alive?(victim) end)

    # live volatile claim: a fresh rollback's claim_undo gets :taken, undo does not re-run
    assert {:ok, []} = Unwind.run(s, id)
    assert Effects.count(@log, {:undo_started, :a}) == 1

    # lease lapse (test clock): the undo re-runs and is marked only after it succeeds
    Clock.advance(31_000)
    assert {:ok, []} = Unwind.run(s, id)
    assert Effects.count(@log, {:undo_started, :a}) == 2

    [cp] = Ets.checkpoints(s, id) |> Map.values()
    assert cp.undone_at != nil
    assert Ets.standing(s, id) == []
  end

  test "a DETS store killed mid-undo loses the volatile claim: the checkpoint stands again" do
    dir = System.tmp_dir!()
    path = Path.join(dir, "unwind_crash_#{System.unique_integer([:positive])}.dets")

    {:ok, s} = Dets.start_link(path: path)
    id = "r1"
    {:ok, _} = Dets.start_run(s, %{id: id, context: identity_context()})
    {:ok, cp} =
      Dets.record(s, id, Key.for_name(:a), Key.label(:a), {:out, :a}, %{
        impl: {BlockingUndoStep, [log: @log, effect: :a]},
        args: %{who: :a}
      })

    victim = spawn(fn -> Unwind.run(s, id, store_module: Dets) end)
    wait_until(fn -> Effects.count(@log, {:undo_started, :a}) == 1 end)
    Process.exit(victim, :kill)
    wait_until(fn -> not Process.alive?(victim) end)

    # kill the STORE itself (real kill-injection): volatile claims die with the server
    Process.exit(s, :kill)
    wait_until(fn -> not Process.alive?(s) end)

    {:ok, s2} = Dets.start_link(path: path)
    on_exit(fn -> if Process.alive?(s2), do: GenServer.stop(s2) end)

    # the checkpoint stands again (undone_at never written, claim gone with the server)
    assert [%{step_key: ^cp.step_key}] = Dets.standing(s2, id)

    # and the next rollback completes the undo, marking after the effect
    assert {:ok, []} = Unwind.run(s2, id, store_module: Dets)
    assert Dets.standing(s2, id) == []
  end
end

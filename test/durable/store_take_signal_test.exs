defmodule AshPPlan.Reactor.Durable.StoreTakeSignalTest do
  @moduledoc """
  Lane Z1 court: atomic consume-once `take_signal/7` across all three stores.

  Laws (per store: Ets, Dets, Wal):

    * `take_signal_atomic` - one store message delivers payload-as-checkpoint: payload lands in
      `cp.output`, the signal is consumed, the waiter is released, and any re-take (same or
      different step key) answers `:none` (strict consume-once).
    * `replay_adopt` - a crash-after-commit world (checkpoint standing, signal still pending)
      adopts: signal consumed, waiter released, existing output returned, never a second
      checkpoint row. The ADOPT-consume transition fires only against a pending signal — never
      adopt-regardless.
    * `kill_between` - the caller is killed after the store commit but before it can act on the
      reply; the re-take answers `:none` and the payload stays durable in the standing
      checkpoint (engine recovery replays from the standing set). No lost signal, no double
      checkpoint. The wrapper store below is a real delegating store
      (all state in the real store-under-test), not a mock - the kill is the injected fault.
  """

  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.Store.{Dets, Ets, Wal}

  @t0 ~U[2026-01-01 00:00:00.000Z]
  @key "step-key-z1"

  # -- kill-between wrapper: real delegating store with a post-commit kill ---------------------

  defmodule KillAfterCommitStore do
    @behaviour AshPPlan.Reactor.Durable.Store

    @doc false
    def start(inner_mod, handle), do: {inner_mod, handle}

    # store handle = {inner_mod, real_handle}: every callback delegates to the real
    # store-under-test (all state lives there), except take_signal, which kills the caller
    # right AFTER the inner commit.
    for {f, a} <- AshPPlan.Reactor.Durable.Store.behaviour_info(:callbacks) do
      args = Macro.generate_arguments(a, __MODULE__)

      def unquote(f)(store = {mod, _handle}, unquote_splicing(args)) do
        delegated = apply(mod, unquote(f), [elem(store, 1), unquote_splicing(args)])
        post_commit_kill(unquote(f), delegated)
      end
    end

    defp post_commit_kill(:take_signal, result) do
      # The atomic commit already happened inside the inner store (durable before the reply).
      # Killing the caller here is exactly the crash window: the caller dies without having
      # recorded anything anywhere. Fires only on the real take ({:ok, _}), never on :none.
      case result do
        {:ok, _cp} ->
          Process.exit(self(), :kill)
          {:error, :unreachable}

        other ->
          other
      end
    end

    defp post_commit_kill(_fun, result), do: result
  end

  # -- store boot and dispatch helpers ---------------------------------------------------------

  defp boot(:ets) do
    {:ok, pid} = Ets.start_link()
    {Ets, pid}
  end

  defp boot(:dets) do
    path = Path.join(System.tmp_dir!(), "z1-take-signal-#{System.unique_integer([:positive])}")
    {:ok, pid} = Dets.start_link(path: path)

    ExUnit.Callbacks.on_exit(fn ->
      File.rm(path)
    end)

    {Dets, pid}
  end

  defp boot(:wal) do
    path =
      Path.join(System.tmp_dir!(), "z1-take-signal-#{System.unique_integer([:positive])}.wal")

    {:ok, handle} = Wal.open(path)
    {Wal, handle}
  end

  # boot the store, start a unique run; every callback is invoked as mod.f(handle, ...)
  defp fresh(kind) do
    s = boot(kind)
    {mod, handle} = s
    run = "r#{System.unique_integer([:positive])}"
    {:ok, _} = mod.start_run(handle, %{id: run})
    {s, run}
  end

  defp q({mod, handle}, f, args), do: apply(mod, f, [handle | args])

  # -- laws, one test per store ----------------------------------------------------------------

  for kind <- [:ets, :dets, :wal] do
    test "take_signal_atomic #{kind}" do
      {s, run} = fresh(unquote(kind))
      k = unquote(@key)

      assert {:ok, _} = q(s, :park, [run, "go", :signal, nil, []])
      assert {:ok, _} = q(s, :deliver_signal, [run, "go", {:payload, 1}])

      assert {:ok, cp} = q(s, :take_signal, [run, "go", k, "go step", %{name: "go"}, @t0])
      assert cp.output == {:payload, 1}
      assert cp.step_key == k
      assert cp.name == "go"

      # signal consumed, waiter released, consume-once (a DIFFERENT step gets :none)
      assert q(s, :pending_signal, [run, "go"]) == nil
      assert q(s, :get_waiter, [run, "go"]) == nil
      assert Enum.all?(q(s, :signals, [run]), &(&1.consumed_at != nil))
      assert q(s, :take_signal, [run, "go", k <> "x", "other", %{name: "go"}, @t0]) == :none

      # the taken signal's payload is durable as the checkpoint: exactly one standing row
      assert [%{step_key: ^k}] = Enum.filter(q(s, :standing, [run]), &(&1.step_key == k))

      # strict consume-once law: the signal was consumed by the first take, so EVERY re-take
      # (same key or different key) answers `:none`; the payload stays durable in the standing
      # checkpoint (engine recovery replays from the standing set, not from take_signal).
      assert q(s, :take_signal, [run, "go", k, "go step", %{name: "go"}, @t0]) == :none

      assert [%{step_key: ^k, output: {:payload, 1}}] =
               Enum.filter(q(s, :standing, [run]), &(&1.step_key == k))
    end

    test "replay_adopt #{kind}" do
      {s, run} = fresh(unquote(kind))
      k = unquote(@key)

      # crash-after-commit world: checkpoint standing, signal still pending
      {:ok, cp} = q(s, :record, [run, k, "go step", :original, %{name: "go"}])
      {:ok, _} = q(s, :deliver_signal, [run, "go", {:payload, 2}])
      {:ok, _} = q(s, :park, [run, "go", :signal, nil, []])

      assert {:ok, ^cp} = q(s, :take_signal, [run, "go", k, "go step", %{name: "go"}, @t0])
      assert cp.output == :original

      assert q(s, :pending_signal, [run, "go"]) == nil
      assert q(s, :get_waiter, [run, "go"]) == nil

      # adoption never mints a second checkpoint row for the key
      assert [%{output: :original}] =
               Enum.filter(q(s, :standing, [run]), &(&1.step_key == k))
    end

    test "kill_between #{kind}" do
      {s, run} = fresh(unquote(kind))
      k = unquote(@key)
      {:ok, _} = q(s, :deliver_signal, [run, "go", {:payload, 3}])

      killer = KillAfterCommitStore.start(elem(s, 0), elem(s, 1))

      # the caller takes through the wrapper and is killed after the store commit, before it
      # can act on the reply; a throwaway process so the test process survives the kill
      _ =
        Task.async(fn ->
          q(killer, :take_signal, [run, "go", k, "go step", %{name: "go"}, @t0])
        end)
        |> Task.await(5_000)

      # strict law: the re-take answers `:none` (the signal was consumed by the killed caller's
      # committed take). No lost payload: it stays durable in the standing checkpoint — engine
      # recovery replays from the standing set, so the step result is not lost to the crash.
      assert q(s, :take_signal, [run, "go", k, "go step", %{name: "go"}, @t0]) == :none

      # no lost signal (consumed), no double checkpoint (exactly one standing row for the key)
      assert q(s, :pending_signal, [run, "go"]) == nil

      assert [%{output: {:payload, 3}}] =
               Enum.filter(q(s, :standing, [run]), &(&1.step_key == k))

      # a different step key with the (now consumed) signal gone answers :none
      assert q(s, :take_signal, [run, "go", k <> "x", "other", %{name: "go"}, @t0]) == :none
    end
  end
end

defmodule AshPPlan.Reactor.Durable.CrashStore do
  @moduledoc """
  A real `AshPPlan.Reactor.Durable.Store` that delegates every callback to the ETS store and, at
  one armed phase boundary, kills the attempt process outright (`Process.exit(pid, :kill)`).

  This is a hand-written implementation of the store interface, not a mock: all state lives in the
  real ETS store, nothing is stubbed or call-counted. The kill plan lives in a named Agent so it is
  data shared by the test and the (killed) attempt. Phases: `:after_claim`, `:after_record`,
  `:after_park`, `:before_release_claim`; `nth` fires on the nth occurrence of the phase.
  """
  @behaviour AshPPlan.Reactor.Durable.Store

  alias AshPPlan.Reactor.Durable.Store.Ets

  @plan __MODULE__.Plan

  def start_plan, do: Agent.start_link(fn -> %{} end, name: @plan)

  @doc "Arm one kill. The attempt process (`victim`) is killed at the nth `phase` boundary."
  def arm(phase, nth, victim),
    do: Agent.update(@plan, fn _ -> %{phase: phase, left: nth, victim: victim, fired: false} end)

  def set_victim(victim), do: Agent.update(@plan, &Map.put(&1, :victim, victim))
  def fired?, do: Agent.get(@plan, &Map.get(&1, :fired, false))
  def disarm, do: Agent.update(@plan, fn _ -> %{} end)

  defp point(phase) do
    victim =
      Agent.get_and_update(@plan, fn
        %{phase: ^phase, left: 1, victim: v} = p -> {v, %{p | phase: nil, fired: true}}
        %{phase: ^phase, left: n} = p -> {nil, %{p | left: n - 1}}
        p -> {nil, p}
      end)

    if victim do
      Process.exit(victim, :kill)
      # If the victim is another process, make sure the caller does not run on past the boundary.
      if victim != self(), do: Process.sleep(:infinity)
    end

    :ok
  end

  @impl true
  def start_run(s, a), do: Ets.start_run(s, a)
  @impl true
  def get_run(s, id), do: Ets.get_run(s, id)
  @impl true
  def list_runs(s), do: Ets.list_runs(s)
  @impl true
  def transition(s, id, from, to, attrs), do: Ets.transition(s, id, from, to, attrs)

  @impl true
  def claim(s, id, claimer, lease, now) do
    result = Ets.claim(s, id, claimer, lease, now)
    with {:ok, _} <- result, do: point(:after_claim)
    result
  end

  @impl true
  def release_claim(s, id, claimer) do
    point(:before_release_claim)
    Ets.release_claim(s, id, claimer)
  end

  @impl true
  def checkpoints(s, id), do: Ets.checkpoints(s, id)
  @impl true
  def standing(s, id), do: Ets.standing(s, id)

  @impl true
  def record(s, id, key, label, output, meta) do
    result = Ets.record(s, id, key, label, output, meta)
    point(:after_record)
    result
  end

  @impl true
  def claim_undo(s, id, key, now), do: Ets.claim_undo(s, id, key, now)
  @impl true
  def release_undo(s, id, key), do: Ets.release_undo(s, id, key)
  @impl true
  def deliver_signal(s, id, name, payload), do: Ets.deliver_signal(s, id, name, payload)
  @impl true
  def pending_signal(s, id, name), do: Ets.pending_signal(s, id, name)
  @impl true
  def consume_signal(s, sid, now), do: Ets.consume_signal(s, sid, now)

  @impl true
  def park(s, id, name, kind, deadline, opts) do
    result = Ets.park(s, id, name, kind, deadline, opts)
    point(:after_park)
    result
  end

  @impl true
  def get_waiter(s, id, name), do: Ets.get_waiter(s, id, name)
  @impl true
  def waiters(s, id), do: Ets.waiters(s, id)
  @impl true
  def release(s, id, name), do: Ets.release(s, id, name)
  @impl true
  def release_all(s, id), do: Ets.release_all(s, id)
  @impl true
  def signals(s, id), do: Ets.signals(s, id)
end

defmodule AshPPlan.Reactor.Durable.PhaseKillTest do
  @moduledoc """
  Kill-at-each-phase-boundary court for the durable engine.

  An attempt process is killed (untrappable) at four boundaries: right after the claim is taken,
  right after a checkpoint is recorded, right after the waiter is parked but before the run status
  is written, and right before the claim is released. After each kill the court lets the lease
  lapse (test clock), delivers the human-release signal and drains the engine. Convergence means:
  the run reaches `:completed`, every consequential effect (`admit`, `authorize`, `commit`) ran
  exactly once, and the standing tape holds each step exactly once.

  Anti-vacuity: (1) every scenario asserts the kill actually fired (a plan that never fires
  fails); (2) a second run of the same plan under a fresh id repeats the effects (counters reach
  2), proving the exactly-once assertion can fail.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.{Clock, CrashStore, Engine, Testing}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Test.{DurableFx, Effects}

  @lease_lapse_ms 3_600_000

  setup do
    DurableFx.install_adapter!()
    Clock.use_test_clock()
    on_exit(&Clock.reset/0)
    {:ok, store} = Ets.start_link()
    {:ok, _} = Effects.start_link()
    {:ok, _} = CrashStore.start_plan()
    {:ok, store: store}
  end

  defp attempt_killed(store, run_id, phase, nth) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        send(parent, {:victim, self()})
        CrashStore.arm(phase, nth, self())
        Engine.attempt(store, run_id, store_module: CrashStore)
        send(parent, :attempt_survived)
      end)

    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 15_000
    reason
  end

  defp converge(store, run_id) do
    CrashStore.disarm()
    Clock.advance(@lease_lapse_ms)
    {:ok, _} = Engine.signal(store, run_id, DurableFx.signal_name(), :approved)
    Testing.drain(store, store_module: CrashStore, max_rounds: 20)
  end

  defp assert_converged(store, run_id) do
    assert Testing.status(store, run_id) == :completed
    assert Effects.all() == %{admit: 1, authorize: 1, commit: 1}
    tape = Testing.tape(store, run_id)
    assert length(tape) == length(Enum.uniq(tape)), "a step is standing twice: #{inspect(tape)}"
    assert length(tape) == 4
  end

  # {phase, nth, whether the signal is delivered before the killed attempt}
  scenarios = [
    {:after_claim, 1, :signal_after},
    {:after_claim, 1, :signal_before},
    {:after_record, 1, :signal_after},
    {:after_record, 2, :signal_after},
    {:after_park, 1, :signal_after},
    {:before_release_claim, 1, :signal_after},
    {:before_release_claim, 1, :signal_before}
  ]

  for {phase, nth, order} <- scenarios do
    test "killed #{phase} (##{nth}, #{order}): state converges, no effect repeats", %{
      store: store
    } do
      phase = unquote(phase)
      id = "kill-#{phase}-#{unquote(nth)}-#{unquote(order)}"
      {:ok, _} = Engine.start(store, DurableFx.attrs(id))

      if unquote(order) == :signal_before do
        {:ok, _} = Engine.signal(store, id, DurableFx.signal_name(), :approved)
      end

      assert :killed = attempt_killed(store, id, phase, unquote(nth))
      assert CrashStore.fired?(), "kill plan never fired at #{phase}"
      refute_received :attempt_survived

      # The killed attempt left a non-terminal run behind, except when the outcome was already
      # written and only the claim release was lost (completed is then legitimate and absorbing).
      if unquote(phase) == :before_release_claim and unquote(order) == :signal_before do
        assert Testing.status(store, id) == :completed
      else
        refute Testing.status(store, id) in [:completed, :failed, :cancelled]
      end

      converge(store, id)
      assert_converged(store, id)
    end
  end

  test "a terminal run is not re-run after a late kill", %{store: store} do
    id = "kill-terminal"
    {:ok, _} = Engine.start(store, DurableFx.attrs(id))
    {:ok, _} = Engine.signal(store, id, DurableFx.signal_name(), :approved)
    Testing.drain(store, store_module: CrashStore)
    assert Testing.status(store, id) == :completed

    counts = Effects.all()
    assert Engine.attempt(store, id, store_module: CrashStore) == :ended
    assert Effects.all() == counts
  end

  test "anti-vacuity: a fresh run of the same plan repeats the effects", %{store: store} do
    {:ok, _} = Engine.start(store, DurableFx.attrs("fresh-a"))
    {:ok, _} = Engine.signal(store, "fresh-a", DurableFx.signal_name(), :approved)
    Testing.drain(store, store_module: CrashStore)
    assert Effects.all() == %{admit: 1, authorize: 1, commit: 1}

    {:ok, _} = Engine.start(store, DurableFx.attrs("fresh-b"))
    {:ok, _} = Engine.signal(store, "fresh-b", DurableFx.signal_name(), :approved)
    Testing.drain(store, store_module: CrashStore)
    assert Effects.all() == %{admit: 2, authorize: 2, commit: 2}
  end

  test "anti-vacuity: an unarmed plan does not kill", %{store: store} do
    {:ok, _} = Engine.start(store, DurableFx.attrs("unarmed"))
    CrashStore.disarm()
    assert {:parked, _} = Engine.attempt(store, "unarmed", store_module: CrashStore)
    refute CrashStore.fired?()
  end
end

defmodule AshPPlan.Test.Chaos.Store do
  @moduledoc """
  A real `AshPPlan.Reactor.Durable.Store` that delegates every callback to the ETS store and, at
  one armed phase boundary, kills the attempt process outright (`Process.exit(pid, :kill)`).
  Hand-written store implementation for the chaos suite (same shape as the phase-kill court).

  This is a hand-written implementation of the store interface, not a mock: all state lives in the
  real ETS store, nothing is stubbed or call-counted. The kill plan lives in a named Agent so it is
  data shared by the test and the (killed) attempt. Phases: `:after_claim`, `:after_record`,
  `:after_park`, `:before_release_claim`; `nth` fires on the nth occurrence of the phase.
  """
  @behaviour AshPPlan.Reactor.Durable.Store

  alias AshPPlan.Reactor.Durable.Store.Ets

  @plan __MODULE__.Plan

  def start_plan, do: Agent.start_link(fn -> %{} end, name: @plan)
  def stop_plan, do: if(Process.whereis(@plan), do: Agent.stop(@plan), else: :ok)

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

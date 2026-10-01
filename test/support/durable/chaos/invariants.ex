defmodule AshPPlan.Test.Chaos.Invariants do
  @moduledoc """
  The invariants a chaos observation (see `AshPPlan.Test.Chaos.Harness.run/1`) must satisfy. Each
  `check/2` answers `:ok` or `{:error, reason}`; the property modules in `test/durable/chaos/`
  are generated from `priv/ggen/ash-pplan-durable-chaos-pack/ontology.ttl`, which names these ids.

  `invariant_ids/0` is the single list the generated suite is checked against.
  """

  @ids ~w(at_most_once replay_identity terminal_absorbing no_lost_wakeup standing_unique cancel_sticky)a

  @spec invariant_ids() :: [atom()]
  def invariant_ids, do: @ids

  @spec check(atom(), map()) :: :ok | {:error, term()}
  def check(:at_most_once, o) do
    bad = Enum.filter(o.final_counts, fn {_, n} -> n > 1 end)
    over_trace = for %{counts: c} <- o.trace, {k, n} <- c, n > 1, do: {k, n}

    if bad == [] and over_trace == [],
      do: :ok,
      else: {:error, {:effect_repeated, bad ++ over_trace}}
  end

  def check(:replay_identity, %{final_status: :completed} = o) do
    b = o.before_probe
    a = o.after_probe

    cond do
      a.counts != b.counts -> {:error, {:replay_reexecuted, b.counts, a.counts}}
      a.outputs != b.outputs -> {:error, {:replay_outputs_differ, b.outputs, a.outputs}}
      true -> :ok
    end
  end

  def check(:replay_identity, _), do: :ok

  def check(:terminal_absorbing, o) do
    cond do
      not o.terminal? ->
        {:error, {:not_terminal_after_heal, o.final_status, o.drain_rounds}}

      o.after_probe != o.before_probe ->
        {:error, {:terminal_changed, o.before_probe, o.after_probe}}

      true ->
        :ok
    end
  end

  def check(:no_lost_wakeup, %{cancel: nil} = o) do
    w = o.wake

    cond do
      o.final_status != :completed ->
        {:error, {:stuck, o.final_status, o.wake, o.drain_rounds}}

      not (w.status in [:completed, :failed, :cancelled] or w.runnable or w.poll_waiters > 0) ->
        {:error, {:signals_delivered_but_not_runnable, w}}

      true ->
        :ok
    end
  end

  def check(:no_lost_wakeup, _), do: :ok

  def check(:standing_unique, o) do
    keys = o.after_probe.step_keys
    tapes = [o.final_tape | Enum.map(o.trace, & &1.tape)]

    cond do
      length(keys) != length(Enum.uniq(keys)) ->
        {:error, {:duplicate_step_keys, keys}}

      Enum.any?(tapes, &(length(&1) != length(Enum.uniq(&1)))) ->
        {:error, {:duplicate_standing, tapes}}

      true ->
        :ok
    end
  end

  def check(:cancel_sticky, %{cancel: nil}), do: :ok

  def check(:cancel_sticky, o) do
    after_cancel = o.trace |> Enum.drop_while(&is_nil(&1.cancel))

    bad =
      Enum.reject(
        after_cancel,
        &(&1.status in [:cancelling, :unwinding, :cancelled, :unwind_blocked])
      )

    cond do
      bad != [] ->
        {:error, {:cancel_overwritten, Enum.map(bad, &{&1.op, &1.status})}}

      o.final_status not in [:cancelled, :unwind_blocked] ->
        {:error, {:cancel_lost, o.final_status}}

      true ->
        :ok
    end
  end
end

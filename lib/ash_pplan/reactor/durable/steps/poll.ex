defmodule AshPPlan.Reactor.Durable.Steps.Poll do
  @moduledoc """
  Checks a condition on an interval until it holds.

  `until` is `{m, f, a}` called as `m.f(arguments, context, ...a)` and answers `{:ok, value}` or
  `:not_yet`. While not satisfied the step parks a `:poll` waiter whose deadline is now plus
  `every` (clamped to at least 1 ms) and halts with `%{awaiting: label, kind: :poll, deadline: dt}`.
  On success the waiter is released, so a stale poll waiter cannot mislead status or wake logic.
  Individual unsatisfied checks hold no checkpoint.

  Design derived from mbuhot/magma (MIT per its mix.exs).
  """
  use Reactor.Step

  alias AshPPlan.Reactor.Durable.{Clock, Key}
  alias AshPPlan.Reactor.Durable.Steps.Await

  @default_every 30_000

  @impl true
  def run(arguments, context, options) do
    :ok = Await.assert_own_step!(context)
    %{store: store, run_id: run_id} = context.durable
    mod = Await.store_module(context)
    name = Key.label(context.current_step.name)
    {m, f, a} = Keyword.fetch!(options, :until)

    case apply(m, f, [arguments, context | a]) do
      {:ok, value} ->
        :ok = mod.release(store, run_id, name)
        {:ok, value}

      :not_yet ->
        every = max(Keyword.get(options, :every, @default_every), 1)
        deadline = Clock.add(Clock.now(), every)
        {:ok, _} = mod.park(store, run_id, name, :poll, deadline, overwrite: true)
        {:halt, %{awaiting: name, kind: :poll, deadline: deadline}}
    end
  end
end

defmodule AshPPlan.Reactor.Durable.TimeoutError do
  @moduledoc "Returned when a durable wait reaches its deadline without its signal."
  defexception [:signal]

  @impl true
  def message(%{signal: signal}), do: "waiting for #{inspect(signal)} reached its deadline"
end

defmodule AshPPlan.Reactor.Durable.Steps.Await do
  @moduledoc """
  Waits for a signal: takes one already delivered, otherwise parks a waiter and halts.

  Ordering is take, park, take, block, take: a signal delivered before the step is reached is a
  non-event, and parking before the re-check closes the delivery race. `block_ms` (default 0)
  holds the process briefly for a signal expected in moments; past it the step halts with
  `%{awaiting: name, kind: :signal, deadline: dt}` and the run becomes a row holding no process.

  The deadline is measured once, when the waiter is first parked, and read back from the waiter
  on every later attempt, so it cannot move. At the deadline the step returns
  `{:error, %TimeoutError{}}` or, with `on_timeout: :return`, `{:ok, {:timeout, name}}`.

  Options are data: `signal` (String or `{m, f, a}` called as `m.f(arguments, context, ...a)`),
  `timeout` (ms, `{m, f, a}` or nil), `on_timeout` (`:error | :return`), `block_ms`.

  Design derived from mbuhot/magma (MIT per its mix.exs).
  """
  use Reactor.Step

  alias AshPPlan.Reactor.Durable.{Clock, TimeoutError}

  @poll_slice 10

  @impl true
  def run(arguments, context, options) do
    :ok = assert_own_step!(context)
    %{store: store, run_id: run_id} = context.durable
    mod = store_module(context)
    name = resolve_name(Keyword.fetch!(options, :signal), arguments, context)

    case take(mod, store, run_id, name) do
      {:ok, payload} -> {:ok, payload}
      :none -> park_and_block(mod, store, run_id, name, arguments, context, options)
    end
  end

  defp park_and_block(mod, store, run_id, name, arguments, context, options) do
    deadline = park(mod, store, run_id, name, arguments, context, options)

    case take(mod, store, run_id, name) do
      {:ok, payload} ->
        {:ok, payload}

      :none ->
        block(Keyword.get(options, :block_ms, 0), mod, store, run_id, name)

        case take(mod, store, run_id, name) do
          {:ok, payload} -> {:ok, payload}
          :none -> expired_or_halt(mod, store, run_id, name, options, deadline)
        end
    end
  end

  defp block(ms, _mod, _store, _run_id, _name) when ms <= 0, do: :ok

  defp block(ms, mod, store, run_id, name) do
    if mod.pending_signal(store, run_id, name) do
      :ok
    else
      slice = min(ms, @poll_slice)
      Process.sleep(slice)
      block(ms - slice, mod, store, run_id, name)
    end
  end

  defp expired_or_halt(mod, store, run_id, name, options, deadline) do
    if deadline && DateTime.compare(Clock.now(), deadline) != :lt do
      :ok = mod.release(store, run_id, name)

      case Keyword.get(options, :on_timeout, :error) do
        :return -> {:ok, {:timeout, name}}
        :error -> {:error, %TimeoutError{signal: name}}
      end
    else
      {:halt, %{awaiting: name, kind: :signal, deadline: deadline}}
    end
  end

  # Consume-once and conditional: losing the race means look for the next signal.
  defp take(mod, store, run_id, name) do
    case mod.pending_signal(store, run_id, name) do
      nil ->
        :none

      signal ->
        case mod.consume_signal(store, signal.id, Clock.now()) do
          {:ok, _} ->
            :ok = mod.release(store, run_id, name)
            {:ok, signal.payload}

          :taken ->
            take(mod, store, run_id, name)
        end
    end
  end

  # A parked waiter's deadline is read back, never recomputed.
  defp park(mod, store, run_id, name, arguments, context, options) do
    case mod.get_waiter(store, run_id, name) do
      %{deadline: deadline} ->
        deadline

      nil ->
        deadline =
          case resolve_timeout(Keyword.get(options, :timeout), arguments, context) do
            nil -> nil
            ms -> Clock.add(Clock.now(), ms)
          end

        {:ok, waiter} = mod.park(store, run_id, name, :signal, deadline, [])
        waiter.deadline
    end
  end

  defp resolve_name(name, _a, _c) when is_binary(name), do: name
  defp resolve_name({m, f, a}, arguments, context), do: apply(m, f, [arguments, context | a])

  defp resolve_timeout({m, f, a}, arguments, context),
    do: apply(m, f, [arguments, context | a])

  defp resolve_timeout(ms, _arguments, _context), do: ms

  @doc false
  def assert_own_step!(%{durable: %{}, durable_step: _}), do: :ok

  def assert_own_step!(_context) do
    raise ArgumentError,
          "Durable.Steps.Await must run as a step of its own durable plan (no context.durable_step)"
  end

  @doc false
  def store_module(context),
    do: Map.get(context.durable, :store_module, AshPPlan.Reactor.Durable.Store.Ets)
end

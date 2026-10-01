defmodule AshPPlan.Reactor.Durable.Steps.Dispatch do
  @moduledoc """
  Runs another workflow as a durable child run and waits for it.

  The child id is derived from the parent run id and this step's name
  (`AshPPlan.Reactor.Durable.Key.child_id/2`), so a replay adopts the child already there rather
  than starting a second one, and the workflow the child runs may be decided at run time while its
  identity stays stable. The child has its own run row, its own tape and its own attempts.

  Options are data: `workflow` is `{m, f, a}` called as `m.f(arguments, context, ...a)` and
  answering a `%{model:, bindings:}` child spec (or `{:ok, spec}`); `inputs` is a map, `{m, f, a}`
  (same calling convention) or nil (the step arguments); `timeout` is milliseconds, `{m, f, a}` or
  nil; `async?` (default false) returns `{:ok, %{child_id: id}}` as soon as the child exists.

  The child's row records how it ended, so a child already terminal is answered from that row; the
  completion report is only a wake-up, and an attempt that finds the child already ended consumes
  any pending report and releases the wait. A child that did not complete reaches the caller as a
  `AshPPlan.Reactor.Durable.ChildError`. If the parent unwinds, `undo/4` cancels a child that is
  still live.

  Design derived from mbuhot/magma (MIT per its mix.exs), re-implemented.
  """
  use Reactor.Step

  alias AshPPlan.Reactor.Durable.{ChildError, Clock, Engine, Key, Status}
  alias AshPPlan.Reactor.Durable.Steps.Await

  @signal_prefix "ash_pplan.child."

  @doc "Name of the signal a child sends its parent for the dispatching step `step_name`."
  @spec signal_name(term()) :: String.t()
  def signal_name(step_name), do: @signal_prefix <> Key.label(step_name)

  @impl true
  def run(arguments, context, options) do
    :ok = Await.assert_own_step!(context)
    %{store: store, run_id: parent_id} = context.durable
    mod = Await.store_module(context)
    name = context.current_step.name
    child_id = Key.child_id(parent_id, name)
    signal = signal_name(name)

    case adopt_or_start(mod, store, child_id, parent_id, signal, arguments, context, options) do
      {:ended, child} ->
        clear_report(mod, store, parent_id, signal)
        outcome(child)

      {:live, _child} ->
        if Keyword.get(options, :async?, false) do
          {:ok, %{child_id: child_id}}
        else
          wait(mod, store, child_id, signal, arguments, context, options)
        end
    end
  end

  @impl true
  def undo(_result, _arguments, context, _options) do
    with %{durable: %{store: store, run_id: parent_id}} <- context,
         mod = Await.store_module(context),
         %{} = child <- find_child(mod, store, parent_id, context),
         false <- Status.terminal?(child.status) do
      case Engine.cancel(store, child.id, store_module: mod) do
        {:ok, _} -> :ok
        {:error, _} -> :ok
      end
    else
      _ -> :ok
    end
  end

  # The unwinder rebuilds the step with the checkpoint label as its name, so the child is found by
  # the signal it reports to rather than by recomputing the id.
  defp find_child(mod, store, parent_id, context) do
    name = context.current_step.name
    wanted = if is_binary(name), do: @signal_prefix <> name, else: signal_name(name)

    Enum.find(mod.list_runs(store), fn r ->
      r.parent_id == parent_id and r.parent_signal == wanted
    end)
  end

  defp adopt_or_start(mod, store, child_id, parent_id, signal, arguments, context, options) do
    case Engine.fetch(store, child_id, store_module: mod) do
      nil ->
        {:ok, child} =
          Engine.start(
            store,
            child_attrs(child_id, parent_id, signal, arguments, context, options),
            store_module: mod
          )

        classify(child)

      child ->
        classify(child)
    end
  end

  defp classify(child),
    do: if(Status.terminal?(child.status), do: {:ended, child}, else: {:live, child})

  defp child_attrs(child_id, parent_id, signal, arguments, context, options) do
    spec = apply_mfa(Keyword.fetch!(options, :workflow), arguments, context)
    spec = with {:ok, s} <- spec, do: s

    %{
      id: child_id,
      model: Map.fetch!(spec, :model),
      bindings: Map.get(spec, :bindings, %{}),
      inputs: resolve_inputs(Keyword.get(options, :inputs), arguments, context),
      context: Map.take(context, [:actor, :tenant]),
      parent: {parent_id, signal}
    }
  end

  defp resolve_inputs(nil, arguments, _context), do: arguments
  defp resolve_inputs({_, _, _} = mfa, arguments, context), do: apply_mfa(mfa, arguments, context)
  defp resolve_inputs(inputs, _arguments, _context) when is_map(inputs), do: inputs

  defp apply_mfa({m, f, a}, arguments, context), do: apply(m, f, [arguments, context | a])

  defp wait(mod, store, child_id, signal, arguments, context, options) do
    await_opts = [
      signal: signal,
      timeout: Keyword.get(options, :timeout),
      on_timeout: :error,
      block_ms: Keyword.get(options, :block_ms, 0)
    ]

    case Await.run(arguments, context, await_opts) do
      {:ok, report} ->
        case Engine.fetch(store, child_id, store_module: mod) do
          %{} = child ->
            if Status.terminal?(child.status),
              do: outcome(child),
              else: reported(child_id, report)

          nil ->
            reported(child_id, report)
        end

      other ->
        other
    end
  end

  defp reported(_child_id, {:ok, result}), do: {:ok, result}

  defp reported(child_id, {:error, error}),
    do: {:error, %ChildError{run_id: child_id, error: error}}

  defp reported(child_id, %{status: status}) when status != :completed,
    do: {:error, %ChildError{run_id: child_id, error: status}}

  defp reported(_child_id, other), do: {:ok, other}

  defp outcome(%{status: :completed, result: result}), do: {:ok, result}

  defp outcome(%{id: id, status: status, error: error}),
    do: {:error, %ChildError{run_id: id, error: error || status}}

  # A child answered from its own row leaves nothing for the parent to hold.
  defp clear_report(mod, store, parent_id, signal) do
    case mod.pending_signal(store, parent_id, signal) do
      nil -> :ok
      pending -> mod.consume_signal(store, pending.id, Clock.now())
    end

    mod.release(store, parent_id, signal)
  end
end

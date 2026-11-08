defmodule AshPPlan.Reactor.Durable.Checkpointed do
  @moduledoc """
  The step implementation every durable step is wrapped in.

  A recorded output comes back from `run/3` (not from a guard): Reactor keeps a guard-skipped
  step off its undo stack, so a replayed value returned that way could never be taken back.
  Replaying through the impl makes it an ordinary success that lands on the undo stack.

  The step about to run is put in the context as `:durable_step`, which is how a recording or
  halting step tells that it is the outer plan's own rather than a child of a nesting composite.
  A step that returns steps is planning and holds no checkpoint; its children are decorated.

  Design derived from mbuhot/magma (MIT per its mix.exs), re-implemented.

  ## Intent token (delivery boundary, P3)

  Before the inner step runs, the wrapper writes a `$intent` checkpoint row
  (first-writer-wins via the store's insert-or-adopt `record/6`) whose output IS the
  deterministic intent token (`Key.intent_id/2` — a pure function of run id + step name),
  handed to the inner step as `context.durable_intent_token`. On the replay after a kill
  between the effect and the record, the standing intent row is adopted and the SAME token
  returns — so a step that derives its external idempotency key from the token dedupes at
  the external system and the at-least-once window closes for it. Steps that ignore the
  token remain at-least-once in that window: the boundary is the checkpoint record, the
  token is a hook for the step's own idempotency. Compose steps get an intent-only wrap:
  the intent row is written but no output checkpoint is recorded, so the nested reactor
  re-runs and undo semantics are unchanged. `$intent` rows are filtered from replay,
  tape, steps and the OCEL export — they are intent metadata, not outputs.
  """
  use Reactor.Step

  require Logger

  alias AshPPlan.Reactor.Durable.Run
  alias AshPPlan.Telemetry.Emit.Event, as: EmitEvent

  @impl true
  def run(arguments, context, options) do
    name = Keyword.fetch!(options, :durable_name)

    case Run.recorded(context, name) do
      {:ok, output} ->
        # Deterministic Replay Guard: Side-effect fence barrier
        {:ok, output}

      :miss ->
        # Live execution: opt-in JPL three-phase lifecycle (default off = zero
        # behavior change for ungated steps). Replay short-circuit above skips
        # every phase.
        case pre_check(arguments, context, options) do
          :ok ->
            run_inner(arguments, context, options, name)

          {:error, reason} ->
            # Refusal is fail-closed: no intent row, no checkpoint, no inner
            # run — zero state mutation.
            emit_refused(context, reason)
            {:error, {:health_gate_violation, reason}}
        end
    end
  end

  # Phase 1: pre_check. Runs BEFORE the intent record (Run.record/4) and
  # before inner execution. Only consulted when the step opts declare
  # `health_gate: module`.
  defp pre_check(arguments, context, options) do
    case options[:health_gate] do
      module when is_atom(module) and not is_nil(module) ->
        if function_exported?(module, :pre_check, 2) do
          case module.pre_check(arguments, context) do
            :ok -> :ok
            # {:ok, _} admits too (gates may report detail alongside admission)
            {:ok, _} -> :ok
            {:error, reason} -> {:error, reason}
            other -> {:error, {:invalid_pre_check_result, other}}
          end
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  # Phase 3: post_telemetry. Runs AFTER Run.record/4 success. Telemetry-only:
  # failures are logged, never raised (a telemetry fault must not fail an
  # already-recorded step).
  defp post_telemetry(value, arguments, context, options) do
    case options[:health_gate] do
      module when is_atom(module) and not is_nil(module) ->
        if function_exported?(module, :post_telemetry, 3) do
          case module.post_telemetry(value, arguments, context) do
            :ok -> :ok
            {:ok, _} -> :ok
            other -> Logger.warning("health_gate post_telemetry returned #{inspect(other)}")
          end
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  defp run_inner(arguments, context, options, name) do
    inner = inner_step(context, options)
    ctx = context |> Map.put(:current_step, inner) |> Map.put(:durable_step, inner)

    # Intent BEFORE the effect (P3): the deterministic intent token is checkpointed
    # first-writer-wins under a `$intent` row, then handed to the inner step via
    # `context.durable_intent_token`. On the replay after a kill-post-effect the
    # standing row is adopted and the SAME token returns, so a step that derives its
    # external idempotency key from the token dedupes at the external system; a step
    # that ignores the token stays at-least-once (documented boundary).
    ctx =
      case Run.record_intent(context, name) do
        {:ok, token} -> Map.put(ctx, :durable_intent_token, token)
        _other -> ctx
      end

    inner
    |> Reactor.Step.run(arguments, ctx)
    |> handle(arguments, context, options, name)
  end

  # Intent-only wrap (compose): the nested reactor re-runs, so the value is passed
  # through WITHOUT an output record - undo semantics unchanged.
  defp handle({:ok, value, steps}, _arguments, context, _options, _name) when is_list(steps),
    do: {:ok, value, Enum.map(steps, &Run.decorate_step(&1, context))}

  defp handle({:ok, value}, arguments, context, options, name) do
    if options[:intent_only] do
      {:ok, value}
    else
      case Run.record(context, name, value, meta(options, arguments)) do
        {:ok, recorded} ->
          post_telemetry(recorded, arguments, context, options)
          emit_checkpoint(context, name)
          {:ok, recorded}

        other ->
          other
      end
    end
  end

  defp handle(other, _arguments, _context, _options, _name), do: other

  @impl true
  def compensate(reason, arguments, context, options) do
    inner = inner_step(context, options)
    name = Keyword.fetch!(options, :durable_name)

    case Reactor.Step.compensate(inner, reason, arguments, %{context | current_step: inner}) do
      {:continue, value} ->
        if options[:intent_only] do
          {:continue, value}
        else
          case Run.record(context, name, value, meta(options, arguments)) do
          {:ok, recorded} ->
            emit_checkpoint(context, name)
            {:continue, recorded}

          {:error, :terminal} -> :ok
          {:error, :cancelling} -> :ok
        end
      end
    end
  end

  @impl true
  def undo(value, arguments, context, options) do
    inner = inner_step(context, options)
    name = Keyword.fetch!(options, :durable_name)

    case Reactor.Step.undo(inner, value, arguments, %{context | current_step: inner}) do
      :ok ->
        # Intent-only wrap holds no output checkpoint, so there is nothing to
        # mark undone - undo semantics identical to the undecorated compose.
        if options[:intent_only], do: :ok, else: Run.mark_undone(context, name)

      other ->
        other
    end
  end

  @impl true
  def can?(%{impl: {__MODULE__, options}} = step, capability),
    do: Reactor.Step.can?(%{step | impl: Keyword.fetch!(options, :durable_inner)}, capability)

  def can?(step, capability), do: super(step, capability)

  @impl true
  def async?(%{impl: {__MODULE__, options}} = step),
    do: Reactor.Step.async?(%{step | impl: Keyword.fetch!(options, :durable_inner)})

  def async?(step), do: super(step)

  @impl true
  def nested_steps(options) do
    case Keyword.fetch!(options, :durable_inner) do
      {module, inner} -> nested(module, inner)
      module -> nested(module, [])
    end
  end

  defp nested(module, inner) do
    if Code.ensure_loaded?(module) and function_exported?(module, :nested_steps, 1),
      do: module.nested_steps(inner),
      else: []
  end

  defp inner_step(context, options),
    do: %{context.current_step | impl: Keyword.fetch!(options, :durable_inner)}

  defp meta(options, arguments),
    do: %{
      impl: normalize(options[:durable_inner]),
      args: arguments,
      name: options[:durable_name]
    }

  defp normalize(m) when is_atom(m), do: {m, []}
  defp normalize(other), do: other

  # Additive telemetry (fire-and-forget, never raises):
  #  * checkpoint_committed — after Run.record/4 succeeds (run + compensate paths)
  #  * invariant_refused — on the fail-closed health-gate pre_check refusal
  defp emit_checkpoint(context, name) do
    case context do
      %{durable: %{store: store, store_module: mod, run_id: run_id}} ->
        AshPPlan.Telemetry.Emit.emit(
          EmitEvent.checkpoint_committed(run_id, mod, meta: %{store: store, step: name}),
          topic: run_id
        )

      _ ->
        :ok
    end
  end

  defp emit_refused(context, reason) do
    run_id =
      case context do
        %{durable: %{run_id: run_id}} -> run_id
        _ -> nil
      end

    AshPPlan.Telemetry.Emit.emit(
      EmitEvent.invariant_refused(run_id, {:health_gate, :pre_check}, detail: reason),
      topic: run_id
    )
  end
end

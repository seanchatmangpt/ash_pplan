defmodule AshPPlan.Reactor.Durable.HealthGate do
  @moduledoc """
  NASA JPL / Mars Rover execution dual: Command Defensiveness & Pre-Actuation Health Gates.

  Introduces an explicit three-phase lifecycle to step execution:
  1. `pre_check/2`: An isolated, side-effect-free assertion (margin >= 22%, lease fresh, circuit open).
  2. `actuate/2`: The singular boundary mutation or external call.
  3. `post_telemetry/3`: Outcome verification and receipt capture.

  Fails closed: when `pre_check/2` returns `{:error, reason}`, `run_fun/2` is
  never invoked, so actuation is genuinely skipped (verified: V5 P8, the
  refusal path runs before any actuation hook). The refusal value is
  `{:error, {:refused, {:health_gate_violation, reason}}}`.

  The former V5-P8 spec/return disagreement is resolved: the `@spec` now
  declares `{:error, {:refused, term()} | term()}`, matching the
  implementation's `{:error, _}` wrapping (alignment landed).

  A step impl whose `pre_check/2` returns a non-`:ok`/non-`{:error, _}`
  value (e.g. an atom) is NOT a silent passthrough: it raises
  `CaseClauseError` (no catch-all clause on the pre-check result; FA2 probe
  2026-11-07: `pre_check/2 -> :weird` rescues as
  `%CaseClauseError{term: :weird}`). Steps without an `impl` key or without
  `function_exported?/3`-visible `pre_check/2` are never gated.
  """

  @doc """
  Executes a step through the three-phase JPL health lifecycle.
  """
  @spec execute(term(), term(), map(), (term(), map() -> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, {:refused, term()} | term()}
  def execute(step, arguments, context, run_fun) do
    step_impl =
      case step do
        %{impl: impl} -> impl
        impl when is_atom(impl) -> impl
        {impl, _opts} -> impl
        _ -> step
      end

    case validate_impl(step_impl) do
      {:error, _} = refused ->
        emit_refused(context, {:health_gate, :invalid_impl})
        refused

      :ok ->
        case run_pre_check(step_impl, arguments, context) do
          :ok ->
            case run_fun.(arguments, context) do
              {:ok, value} = success ->
                run_post_telemetry(step_impl, value, arguments, context)
                success

              {:obligation, obligation} = obl ->
                run_post_telemetry(step_impl, obligation, arguments, context)
                obl

              {:ok, value, _steps} = success ->
                run_post_telemetry(step_impl, value, arguments, context)
                success

              {:error, _reason} = error ->
                error

              other ->
                other
            end

          {:error, reason} ->
            emit_refused(context, reason)
            {:error, {:refused, {:health_gate_violation, reason}}}
        end
    end
  end

  # Fail-closed: a step impl we cannot identify is a refusal, not a silent bypass. A nil impl
  # is a documented no-impl passthrough (nothing to pre-check).
  defp validate_impl(impl) when is_atom(impl) and not is_nil(impl), do: :ok
  defp validate_impl({impl, _opts}) when is_atom(impl) and not is_nil(impl), do: :ok
  defp validate_impl(nil), do: :ok

  defp validate_impl(impl), do: {:error, {:refused, {:health_gate_invalid_impl, impl}}}

  defp run_pre_check(step_impl, arguments, context)
       when is_atom(step_impl) and not is_nil(step_impl) do
    if function_exported?(step_impl, :pre_check, 2) do
      step_impl.pre_check(arguments, context)
    else
      :ok
    end
  end

  defp run_pre_check(_step_impl, _arguments, _context), do: :ok

  defp run_post_telemetry(step_impl, value, arguments, context)
       when is_atom(step_impl) and not is_nil(step_impl) do
    if function_exported?(step_impl, :post_telemetry, 3) do
      step_impl.post_telemetry(value, arguments, context)
    else
      :ok
    end
  end

  defp run_post_telemetry(_step_impl, _value, _arguments, _context), do: :ok

  # Additive telemetry: invariant_refused on the fail-closed refusal paths.
  # Fire-and-forget (never raises); never alters the refusal value.
  defp emit_refused(context, reason) do
    run_id =
      case context do
        %{durable: %{run_id: run_id}} -> run_id
        _ -> nil
      end

    AshPPlan.Telemetry.Emit.emit(
      AshPPlan.Telemetry.Emit.Event.invariant_refused(
        run_id,
        {:health_gate, :pre_check},
        detail: reason
      ),
      topic: run_id
    )
  end
end

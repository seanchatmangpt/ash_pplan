defmodule AshPPlan.Reactor.Durable.HealthGate do
  @moduledoc """
  NASA JPL / Mars Rover execution dual: Command Defensiveness & Pre-Actuation Health Gates.

  Introduces an explicit three-phase lifecycle to step execution:
  1. `pre_check/2`: An isolated, side-effect-free assertion (margin >= 22%, lease fresh, circuit open).
  2. `actuate/2`: The singular boundary mutation or external call.
  3. `post_telemetry/3`: Outcome verification and receipt capture.

  Fails closed into Safe Mode before external side effects can escape if pre-check fails.
  """

  @doc """
  Executes a step through the three-phase JPL health lifecycle.
  """
  @spec execute(term(), term(), map(), (term(), map() -> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:refused, term()} | {:error, term()}
  def execute(step, arguments, context, run_fun) do
    step_impl =
      case step do
        %{impl: impl} -> impl
        impl when is_atom(impl) -> impl
        {impl, _opts} -> impl
        _ -> nil
      end

    case run_pre_check(step_impl, arguments, context) do
      :ok ->
        case run_fun.(arguments, context) do
          {:ok, value} = success ->
            run_post_telemetry(step_impl, value, arguments, context)
            success

          {:ok, value, _steps} = success ->
            run_post_telemetry(step_impl, value, arguments, context)
            success

          {:error, _reason} = error ->
            error

          other ->
            other
        end

      {:error, reason} ->
        {:refused, {:health_gate_violation, reason}}
    end
  end

  defp run_pre_check(step_impl, arguments, context) when is_atom(step_impl) and not is_nil(step_impl) do
    if function_exported?(step_impl, :pre_check, 2) do
      step_impl.pre_check(arguments, context)
    else
      :ok
    end
  end

  defp run_pre_check(_step_impl, _arguments, _context), do: :ok

  defp run_post_telemetry(step_impl, value, arguments, context) when is_atom(step_impl) and not is_nil(step_impl) do
    if function_exported?(step_impl, :post_telemetry, 3) do
      step_impl.post_telemetry(value, arguments, context)
    else
      :ok
    end
  end

  defp run_post_telemetry(_step_impl, _value, _arguments, _context), do: :ok
end

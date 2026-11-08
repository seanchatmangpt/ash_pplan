defmodule AshPPlan.Reactor.Durable.HealthGateTest do
  use ExUnit.Case, async: true

  alias AshPPlan.Reactor.Durable.HealthGate

  defmodule NominalStep do
    def pre_check(_arguments, _context), do: :ok
    def actuate(arguments, _context), do: {:ok, {:result, arguments}}
    def post_telemetry(_result, _arguments, _context), do: :ok
  end

  defmodule RefusedStep do
    def pre_check(_arguments, _context), do: {:error, :safety_margin_violated}
    def actuate(_arguments, _context), do: flunk("actuation should never be called when pre_check fails")
  end

  defmodule LegacyStep do
    # No pre_check or post_telemetry defined
    def actuate(_arguments, _context), do: {:ok, :legacy_success}
  end

  test "nominal step passes pre-check and executes actuation" do
    result =
      HealthGate.execute(NominalStep, %{foo: "bar"}, %{}, fn args, ctx ->
        NominalStep.actuate(args, ctx)
      end)

    assert result == {:ok, {:result, %{foo: "bar"}}}
  end

  test "refused step halts closed before actuation is fired" do
    result =
      HealthGate.execute(RefusedStep, %{}, %{}, fn args, ctx ->
        RefusedStep.actuate(args, ctx)
      end)

    assert result == {:error, {:refused, {:health_gate_violation, :safety_margin_violated}}}
  end

  test "legacy steps without pre_check pass through cleanly" do
    result =
      HealthGate.execute(LegacyStep, %{}, %{}, fn args, ctx ->
        LegacyStep.actuate(args, ctx)
      end)

    assert result == {:ok, :legacy_success}
  end

  test "checkpointed replay short-circuits and skips health gate pre-check" do
    alias AshPPlan.Reactor.Durable.{Checkpointed, Key}

    step_name = "step_alpha"
    key = Key.for_name(step_name)

    # Simulated context with a recorded checkpoint for step_alpha
    context = %{
      current_step: RefusedStep,
      durable: %{
        checkpoints: %{key => :cached_actuation_output}
      }
    }

    options = [durable_name: step_name, inner_step: RefusedStep]

    # RefusedStep would fail pre_check if health gate ran.
    # Checkpointed replay must short-circuit directly and return {:ok, :cached_actuation_output}
    assert {:ok, :cached_actuation_output} = Checkpointed.run(%{}, context, options)
  end

  defmodule TupleImplStep do
    def pre_check(_a, _c), do: :ok
    def actuate(_a, _c), do: {:ok, :tuple_ok}
  end

  test "invalid impl shape fails closed with a typed refusal" do
    result = HealthGate.execute(%{weird: true}, %{}, %{}, fn _a, _c -> {:ok, :ran} end)
    assert result == {:error, {:refused, {:health_gate_invalid_impl, %{weird: true}}}}
    # actuation never ran - the run_fun would have returned :ran
  end

  test "tuple impl {Mod, opts} is accepted" do
    result =
      HealthGate.execute({TupleImplStep, []}, %{}, %{}, fn _a, _c -> {:ok, :tuple_ok} end)

    assert result == {:ok, :tuple_ok}
  end

end

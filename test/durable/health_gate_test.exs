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

    assert result == {:refused, {:health_gate_violation, :safety_margin_violated}}
  end

  test "legacy steps without pre_check pass through cleanly" do
    result =
      HealthGate.execute(LegacyStep, %{}, %{}, fn args, ctx ->
        LegacyStep.actuate(args, ctx)
      end)

    assert result == {:ok, :legacy_success}
  end
end

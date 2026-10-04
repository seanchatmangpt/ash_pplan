defmodule AshPPlan.Reactor.Middleware.Telemetry do
  @moduledoc """
  GENERATED from `priv/ggen/ash-pplan-reactor-mw-pack/ontology.ttl`
  (aexmw:TelemetryMiddleware) via `mix ggen_igniter.sync` -- do not edit by hand.

  Reactor.Middleware cross-cutting telemetry instrumentation, installed via
  `AshPPlan.Reactor.add_middleware/2` (`Reactor.Builder.add_middleware/2`) so no
  step definition carries instrumentation boilerplate (finding 7 / openQuestion 3:
  middleware replaces hand-rolled cross-cutting instrumentation).

  Emits `:telemetry` events `[:ash_pplan, :reactor, :step, phase]` around each
  step execution (derived from the behaviour's `event/3` `run_*` step events) and
  `[:ash_pplan, :reactor, :run, phase]` at reactor init/complete/error/halt.
  """

  use Reactor.Middleware

  @run_prefix [:ash_pplan, :reactor, :run]
  @step_prefix [:ash_pplan, :reactor, :step]
  @started :ash_pplan_telemetry_started

  @doc "Telemetry event prefixes this middleware emits."
  @spec prefixes() :: [[atom()]]
  def prefixes do
    [@run_prefix, @step_prefix]
  end

  @doc "All concrete event names this middleware can emit."
  @spec events() :: [[atom()]]
  def events do
    step_phases = for p <- [:start, :stop, :error, :halt, :retry], do: @step_prefix ++ [p]
    run_phases = for p <- [:start, :stop, :error, :halt], do: @run_prefix ++ [p]
    step_phases ++ run_phases
  end

  @impl true
  def init(context) do
    :telemetry.execute(@run_prefix ++ [:start], %{system_time: System.system_time()}, %{
      middleware: __MODULE__
    })

    {:ok, Map.put(context, @started, System.monotonic_time())}
  end

  @impl true
  def complete(result, context) do
    :telemetry.execute(@run_prefix ++ [:stop], %{duration: duration(context)}, %{
      middleware: __MODULE__,
      result: result
    })

    {:ok, result}
  end

  @impl true
  def error(errors, context) do
    :telemetry.execute(@run_prefix ++ [:error], %{duration: duration(context)}, %{
      middleware: __MODULE__,
      errors: errors
    })

    :ok
  end

  @impl true
  def halt(context) do
    :telemetry.execute(@run_prefix ++ [:halt], %{duration: duration(context)}, %{
      middleware: __MODULE__
    })

    {:ok, context}
  end

  @impl true
  def event(step_event, step, _context) do
    case step_event do
      {:run_start, _args} ->
        :telemetry.execute(@step_prefix ++ [:start], %{system_time: System.system_time()}, %{
          middleware: __MODULE__,
          step: step.name
        })

      {:run_complete, _result} ->
        :telemetry.execute(@step_prefix ++ [:stop], %{system_time: System.system_time()}, %{
          middleware: __MODULE__,
          step: step.name
        })

      {:run_error, _errors} ->
        :telemetry.execute(@step_prefix ++ [:error], %{system_time: System.system_time()}, %{
          middleware: __MODULE__,
          step: step.name
        })

      {:run_halt, _reason} ->
        :telemetry.execute(@step_prefix ++ [:halt], %{system_time: System.system_time()}, %{
          middleware: __MODULE__,
          step: step.name
        })

      {:run_retry, _reason} ->
        :telemetry.execute(@step_prefix ++ [:retry], %{system_time: System.system_time()}, %{
          middleware: __MODULE__,
          step: step.name
        })

      _other ->
        :ok
    end

    :ok
  end

  defp duration(context) do
    key = @started

    case context do
      %{^key => started} -> System.monotonic_time() - started
      _ -> 0
    end
  end
end

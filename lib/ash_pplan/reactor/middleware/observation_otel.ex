if Code.ensure_loaded?(OpenTelemetry.Tracer) do
  defmodule AshPPlan.Reactor.Middleware.Observation.Otel do
    @moduledoc """
    OpenTelemetry span seam for `AshPPlan.Reactor.Middleware.Observation`. Compiled only when
    `opentelemetry_api` (optional dep) is present; absent, the middleware emits telemetry only.
    """
    require OpenTelemetry.Tracer

    def start(identity) do
      OpenTelemetry.Tracer.start_span("ash_pplan.step", %{
        attributes: %{"semantic.task" => identity.task, "semantic.subject_id" => identity.subject}
      })
    end

    def finish(ctx, outcome) do
      case outcome do
        {:error, err} ->
          OpenTelemetry.Span.set_status(ctx, OpenTelemetry.status(:error, inspect(err)))

        _ ->
          :ok
      end

      OpenTelemetry.Span.end_span(ctx)
    end
  end
end

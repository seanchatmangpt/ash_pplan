defmodule AshPPlan.Reactor.Middleware.Observation do
  @moduledoc """
  Reactor middleware that observes every step of a run and resolves each observation to the
  same task subject carried by `AshPPlan.Reactor.enrich/3`.

  Per step lifecycle (`:start`, `:stop`, `:error`, `:halt`) it emits:

    * a `:telemetry` event `[:ash_pplan, :observation, :step, phase]` whose metadata carries
      `:subject_id`, `:task`, `:run_id`, and the matching `AshPPlan.ProcessEvidence.Event`;
    * an OpenTelemetry API span `ash_pplan.step` with attributes `semantic.task` and
      `semantic.subject_id` (a no-op without an SDK, real with one);
    * a structured `Logger` lifecycle line.

  On run completion it emits `[:ash_pplan, :observation, :run, :stop | :error | :halt]` with an
  `AshPPlan.ExecutionReceipt` and its PROV-O N-Triples (`ExecutionReceipt.to_rdf/1`) in metadata.

  Steps without workflow identity are skipped; the run result is never altered and observation
  grants no authority. `AshPPlan.Reactor.Middleware.Observation.Collector` is a real sink for
  tests: it attaches telemetry handlers and accumulates what was emitted.
  """

  use Reactor.Middleware

  require Logger
  require OpenTelemetry.Tracer

  alias AshPPlan.{ExecutionReceipt, ProcessEvidence.Event}

  @key AshPPlan.Reactor.context_key()
  @started :ash_pplan_observation_started

  @doc "Telemetry event names this middleware emits."
  def events do
    steps = for p <- [:start, :stop, :error, :halt], do: [:ash_pplan, :observation, :step, p]
    runs = for p <- [:stop, :error, :halt], do: [:ash_pplan, :observation, :run, p]
    steps ++ runs
  end

  @impl true
  def init(context), do: {:ok, Map.put(context, @started, {DateTime.utc_now(), mono()})}

  @impl true
  def complete(result, context), do: run_done(:succeeded, :stop, result, context)

  @impl true
  def error(errors, context) do
    run_done(:failed, :error, errors, context)
    :ok
  end

  @impl true
  def halt(context) do
    run_done(:halted, :halt, :halted, context)
    {:ok, context}
  end

  @impl true
  def event(event, step, context) do
    case AshPPlan.Reactor.identity_of(step) do
      nil -> :ok
      identity -> observe(event, identity, step, context)
    end

    :ok
  end

  defp observe({:run_start, _args}, identity, _step, context) do
    span_start(identity)
    step_emit(:start, identity, context, nil)
  end

  defp observe({:run_complete, _r}, identity, _step, context) do
    span_end(identity, :ok)
    step_emit(:stop, identity, context, nil)
  end

  defp observe({:run_error, err}, identity, _step, context) do
    span_end(identity, {:error, err})
    step_emit(:error, identity, context, err)
  end

  defp observe({:run_halt, _}, identity, _step, context) do
    span_end(identity, :ok)
    step_emit(:halt, identity, context, nil)
  end

  defp observe(_other, _identity, _step, _context), do: :ok

  defp step_emit(phase, identity, context, err) do
    run_id = run_id(context)
    ev = evidence(phase, identity, run_id)

    meta = %{
      subject_id: identity.subject,
      task: identity.task,
      workflow: identity.workflow,
      capability: identity.capability,
      run_id: run_id,
      evidence: ev,
      error: err
    }

    level = if phase == :error, do: :error, else: :info

    Logger.log(level, fn ->
      "ash_pplan.step phase=#{phase} task=#{identity.task} subject=#{identity.subject} run=#{run_id}"
    end)

    :telemetry.execute(
      [:ash_pplan, :observation, :step, phase],
      %{system_time: System.system_time()},
      meta
    )
  end

  defp evidence(phase, identity, run_id) do
    act = %{
      start: "task_attempted",
      stop: "task_succeeded",
      error: "task_failed",
      halt: "task_halted"
    }

    run = "run:" <> run_id

    %Event{
      id: "#{run}/#{identity.task}/#{phase}",
      activity: act[phase],
      timestamp: DateTime.utc_now(),
      objects: [
        {"WorkflowRun", run, "run"},
        {"Capability", "cap:" <> to_string(identity.capability), "capability"}
      ],
      attributes: %{task: identity.task, phase: Atom.to_string(phase)},
      subject_id: identity.subject
    }
  end

  defp run_done(status, phase, payload, context) do
    case context do
      %{@key => %{subject: subject, workflow: workflow}} ->
        {started_at, mono0} = Map.get(context, @started, {DateTime.utc_now(), mono()})
        run_id = run_id(context)

        receipt = %ExecutionReceipt{
          plan_iri: AshPPlan.Workflow.Evidence.plan_iri(subject),
          run_id: run_id,
          status: status,
          started_at: started_at,
          finished_at: DateTime.utc_now(),
          duration_us: max(mono() - mono0, 0),
          outcome_digest:
            :crypto.hash(:sha256, :erlang.term_to_binary(inspect(payload), [:deterministic]))
            |> Base.encode16(case: :lower)
        }

        Logger.info(fn ->
          "ash_pplan.run phase=#{phase} status=#{status} subject=#{subject} run=#{run_id}"
        end)

        :telemetry.execute(
          [:ash_pplan, :observation, :run, phase],
          %{duration_us: receipt.duration_us},
          %{
            subject_id: subject,
            workflow: workflow,
            run_id: run_id,
            receipt: receipt,
            prov: ExecutionReceipt.to_rdf(receipt)
          }
        )

      _ ->
        :ok
    end

    {:ok, payload}
  end

  defp run_id(context),
    do: context |> Map.get(:run_id, "unknown") |> ExecutionReceipt.run_identifier()

  defp mono, do: System.monotonic_time(:microsecond)

  defp span_key(identity), do: {__MODULE__, :span, identity.task}

  defp span_start(identity) do
    ctx =
      OpenTelemetry.Tracer.start_span("ash_pplan.step", %{
        attributes: %{"semantic.task" => identity.task, "semantic.subject_id" => identity.subject}
      })

    Process.put(span_key(identity), ctx)
  end

  defp span_end(identity, outcome) do
    case Process.delete(span_key(identity)) do
      nil ->
        :ok

      ctx ->
        case outcome do
          {:error, err} ->
            OpenTelemetry.Span.set_status(ctx, OpenTelemetry.status(:error, inspect(err)))

          _ ->
            :ok
        end

        OpenTelemetry.Span.end_span(ctx)
    end
  end

  defmodule Collector do
    @moduledoc """
    Real sink for `AshPPlan.Reactor.Middleware.Observation`: an Agent plus telemetry handlers.
    """
    use Agent

    @doc "Start a collector and attach handlers for every observation event."
    def start do
      {:ok, pid} = Agent.start_link(fn -> [] end)
      id = {__MODULE__, pid}

      :telemetry.attach_many(
        id,
        AshPPlan.Reactor.Middleware.Observation.events(),
        &__MODULE__.handle/4,
        pid
      )

      {:ok, pid}
    end

    @doc "Detach handlers and stop."
    def stop(pid) do
      :telemetry.detach({__MODULE__, pid})
      Agent.stop(pid)
    end

    @doc "Collected `{event, measurements, metadata}` tuples in emission order."
    def events(pid), do: Agent.get(pid, &Enum.reverse/1)

    @doc false
    def handle(event, meas, meta, pid) do
      if Process.alive?(pid), do: Agent.update(pid, &[{event, meas, meta} | &1])
    end
  end
end

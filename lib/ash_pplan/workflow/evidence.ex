defmodule AshPPlan.Workflow.Evidence do
  @moduledoc """
  Evidence profile bound to one workflow subject.

  A run of a workflow produces four evidence kinds, every one carrying the
  subject id of the workflow that was run:

    * `:prov` - PROV-O N-Triples rendered by `AshPPlan.ExecutionReceipt.to_rdf/1`,
      plus a link from the receipt to the workflow subject
    * `:ocel` - an OCEL-shaped event (event, objects, attributes)
    * `:telemetry` - a `:telemetry`-shaped `{event_name, measurements, metadata}`
    * `:receipt` - the `AshPPlan.ExecutionReceipt` struct

  Evidence describes what was observed. It grants no authority.
  """

  alias AshPPlan.ExecutionReceipt
  alias AshPPlan.Workflow.{Model, Subject}

  @kinds [:prov, :ocel, :telemetry, :receipt]
  @ap "https://w3id.org/ash-pplan#"
  @telemetry_event [:ash_pplan, :workflow, :run]

  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc "Telemetry event name emitted for a workflow run."
  @spec telemetry_event() :: [atom()]
  def telemetry_event, do: @telemetry_event

  @doc """
  The evidence profile of a workflow: the kinds every run must produce, plus the
  evidence kinds each task declares, keyed by task id.
  """
  @spec profile(Model.t() | map()) :: map()
  def profile(%Model{} = model) do
    subject = Subject.bind(model)

    %{
      subject: subject.id,
      required: @kinds,
      tasks: Map.new(model.tasks, &{&1.id, &1.evidence})
    }
  end

  def profile(%{id: id}), do: %{subject: id, required: @kinds, tasks: %{}}

  @doc """
  Produce all required evidence for a run, bound to the subject.

  Options: `:run_id` (default generated), `:outcome` (a Reactor-shaped outcome,
  default `{:ok, %{}}`), `:started_at`, `:started_mono`, `:emit` (emit the
  telemetry event, default `false`).
  """
  @spec bind(Model.t() | map(), keyword()) :: {:ok, map()} | {:error, map()}
  def bind(subject_or_model, opts \\ [])

  def bind(%Model{} = model, opts), do: bind(Subject.bind(model), opts)

  def bind(%{id: "sha256:" <> _ = subject_id, workflow: workflow}, opts) do
    run_id =
      Keyword.get_lazy(opts, :run_id, fn ->
        "run-" <> Integer.to_string(System.unique_integer([:positive]))
      end)

    outcome = Keyword.get(opts, :outcome, {:ok, %{}})
    started_at = Keyword.get_lazy(opts, :started_at, &DateTime.utc_now/0)

    started_mono =
      Keyword.get_lazy(opts, :started_mono, fn -> System.monotonic_time(:microsecond) end)

    receipt =
      ExecutionReceipt.observe(plan_iri(subject_id), run_id, outcome, started_at, started_mono)

    evidence = %{
      subject_id: subject_id,
      workflow: workflow,
      receipt: receipt,
      prov: prov(receipt, subject_id),
      ocel: ocel(receipt, subject_id, workflow),
      telemetry: telemetry(receipt, subject_id, workflow)
    }

    if Keyword.get(opts, :emit, false), do: emit(evidence.telemetry)
    {:ok, evidence}
  end

  def bind(_other, _opts), do: {:error, %{reason: :unbound_subject}}

  @doc "Subject-bound plan IRI used as `prov:used` target."
  @spec plan_iri(String.t()) :: String.t()
  def plan_iri("sha256:" <> digest), do: "urn:ash-pplan:workflow-subject:" <> digest

  @doc """
  Check that every required evidence kind is present and bound to `subject_id`.
  """
  @spec verify(map(), String.t()) :: :ok | {:error, map()}
  def verify(evidence, subject_id) when is_map(evidence) do
    missing = Enum.reject(@kinds, &Map.get(evidence, &1))

    cond do
      missing != [] ->
        {:error, %{reason: :missing_evidence, kinds: missing}}

      evidence[:subject_id] != subject_id ->
        {:error, %{reason: :subject_mismatch, expected: subject_id, got: evidence[:subject_id]}}

      true ->
        unbound = Enum.reject(@kinds, &bound?(&1, evidence, subject_id))
        if unbound == [], do: :ok, else: {:error, %{reason: :unbound_evidence, kinds: unbound}}
    end
  end

  defp bound?(:receipt, e, id), do: e.receipt.plan_iri == plan_iri(id)

  defp bound?(:prov, e, id),
    do:
      String.contains?(e.prov, "<" <> plan_iri(id) <> ">") and
        String.contains?(e.prov, ~s("#{id}"))

  defp bound?(:ocel, e, id), do: get_in(e.ocel, [:attributes, :subject_id]) == id
  defp bound?(:telemetry, e, id), do: elem(e.telemetry, 2)[:subject_id] == id

  defp prov(receipt, subject_id) do
    receipt_iri = "urn:ash-pplan:receipt:" <> receipt.outcome_digest

    ExecutionReceipt.to_rdf(receipt) <>
      "<#{receipt_iri}> <#{@ap}workflowSubject> \"#{subject_id}\" .\n"
  end

  defp ocel(receipt, subject_id, workflow) do
    run_id = ExecutionReceipt.run_identifier(receipt.run_id)

    %{
      id: "e-" <> run_id,
      type: "workflow.run",
      time: DateTime.to_iso8601(receipt.finished_at),
      objects: [
        %{id: subject_id, type: "workflow_subject"},
        %{id: run_id, type: "workflow_run"},
        %{id: receipt.outcome_digest, type: "receipt"}
      ],
      attributes: %{
        subject_id: subject_id,
        workflow: workflow,
        status: receipt.status
      }
    }
  end

  defp telemetry(receipt, subject_id, workflow) do
    {@telemetry_event, %{duration_us: receipt.duration_us},
     %{
       subject_id: subject_id,
       workflow: workflow,
       status: receipt.status,
       run_id: ExecutionReceipt.run_identifier(receipt.run_id)
     }}
  end

  defp emit({event, measurements, metadata}),
    do: :telemetry.execute(event, measurements, metadata)
end

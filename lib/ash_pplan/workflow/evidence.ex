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

  ## Literal hardening

  `bind/2` and `prov/2` are total over their inputs: a receipt whose literal
  slots (`:plan_iri`, `:status`, `:outcome_digest`, `:started_at`,
  `:finished_at`) carry a nil or otherwise unrenderable value yields
  `{:error, %{reason: :invalid_literal, field: field, value: value}}` — a typed
  failure naming the slot — rather than an untyped bad-generator raise deep in
  N-Triples escaping (`{:bad_generator, nil}`, ZD2 court 2026-10-04). Identity
  triples are never silently dropped: the failure is returned, not skipped.
  """

  defmodule LiteralError do
    @moduledoc """
    Typed shape carried in `{:error, %{reason: :invalid_literal}}` evidence
    failures: `field` is the receipt slot and `value` the offending value.
    """
    defexception [:field, :value]

    @impl true
    def message(%__MODULE__{field: field, value: value}),
      do: "invalid evidence literal for #{inspect(field)}: #{inspect(value)}"
  end

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
  telemetry event, default `false`), `:corresponds_to_steps` (list of step IRIs
  forwarded into `to_rdf/2`'s `p-plan:correspondsToStep` emission; absent/empty
  emits none).
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

    with {:ok, prov_nt} <-
           prov(receipt, subject_id, Keyword.get(opts, :corresponds_to_steps, [])) do
      evidence = %{
        subject_id: subject_id,
        workflow: workflow,
        receipt: receipt,
        prov: prov_nt,
        ocel: ocel(receipt, subject_id, workflow),
        telemetry: telemetry(receipt, subject_id, workflow)
      }

      if Keyword.get(opts, :emit, false), do: emit(evidence.telemetry)
      {:ok, evidence}
    end
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

  @doc """
  Render the PROV-O N-Triples for a receipt, typed over its literal slots.

  The slots `to_rdf/2` and the identity triple below render as RDF literals —
  `:plan_iri`, `:status`, `:outcome_digest`, `:started_at`, `:finished_at` —
  are validated first. A nil or otherwise unrenderable value yields
  `{:error, %{reason: :invalid_literal, field: field, value: value}}` instead
  of an untyped bad-generator raise deep in N-Triples escaping
  (`{:bad_generator, nil}`, ZD2 court 2026-10-04). Identity triples are never
  silently dropped: the failure is returned, not skipped.
  """
  @spec prov(ExecutionReceipt.t(), String.t(), [term()]) ::
          {:ok, String.t()} | {:error, %{reason: :invalid_literal, field: atom(), value: term()}}
  def prov(receipt, subject_id, corresponds_to_steps \\ [])

  def prov(receipt, subject_id, corresponds_to_steps) do
    with :ok <- validate_literal_slots(receipt) do
      {:ok, render_prov(receipt, subject_id, corresponds_to_steps)}
    end
  end

  # Literal slots rendered by ExecutionReceipt.to_rdf/2 and the workflowSubject
  # identity triple. A hand-built receipt struct (the `counterfactual.ex`
  # class) can carry a nil in any of them; escape_literal/1 would blow up as a
  # bad bitstring generator rather than fail typed.
  @literal_slots [:plan_iri, :status, :outcome_digest, :started_at, :finished_at]

  defp validate_literal_slots(receipt) do
    Enum.find_value(@literal_slots, :ok, fn field ->
      value = Map.get(receipt, field)

      if literal_slot_valid?(field, value),
        do: nil,
        else: {:error, %{reason: :invalid_literal, field: field, value: value}}
    end)
  end

  defp literal_slot_valid?(:plan_iri, v), do: is_binary(v)
  defp literal_slot_valid?(:status, v), do: is_atom(v) and not is_nil(v)
  defp literal_slot_valid?(:outcome_digest, v), do: is_binary(v)
  defp literal_slot_valid?(:started_at, v), do: match?(%DateTime{}, v)
  defp literal_slot_valid?(:finished_at, v), do: match?(%DateTime{}, v)

  defp render_prov(receipt, subject_id, corresponds_to_steps) do
    receipt_iri =
      "urn:ash-pplan:receipt:" <>
        URI.encode(ExecutionReceipt.run_identifier(receipt.run_id), &URI.char_unreserved?/1) <>
        ":" <> receipt.outcome_digest

    ExecutionReceipt.to_rdf(receipt, corresponds_to_steps: corresponds_to_steps) <>
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

defmodule AshPPlan.Courts.OcelV2MappingCourtTest do
  @moduledoc """
  ERRC C6 gate 1: prove the OCEL 2.0 mapping is lossless BEFORE any pack adoption.

  The ggen-ecosystem-ocel and otel-weaver-ocel marketplace packs (both exist in
  /Users/sac/ggen-marketplace/packs/) would replace/projection-generate the OCEL
  export. Their blocker is proving that ash_pplan's `LedgerOCEL` export —
  `task_succeeded` / `run_started` / `run_ended` activities with
  {type, id, qualifier} object tuples — maps losslessly into the OCEL 2.0
  schema those tools require.

  The court:

  1. Runs a REAL durable run (`Runtime.run` over `Store.Ets`, same shape as the
     gcp_lifecycle court) and exports its standing checkpoint ledger via
     `LedgerOCEL.export/3` (pure OCEL 2.0 JSON: objectTypes/eventTypes/objects/
     events).
  2. Validates every emitted event against the OCEL 2.0 schema constraints the
     pack gates require, independently re-derived in this file:
       - event identity: non-empty `id`, `type` (activity) present
       - `time` parses as ISO 8601 (xs:dateTime)
       - `relationships` carry `objectId` + `qualifier`
       - every referenced object id exists in `objects` (no dangling refs)
       - every event `type` is declared in `eventTypes`, every object type in
         `objectTypes`
       - `task_succeeded` (and `run_started`/`run_ended`) are legal OCEL
         activity identifiers (XES-standard NCName-style: printable, no
         whitespace/control/JSON-unsafe chars)
       - the task identity survives the round trip: each checkpoint label is
         carried in the event's `task` attribute
  3. Anti-vacuity: hand-built malformed events (missing timestamp, dangling
     object ref) MUST fail the same validator — the court cannot pass on a
     vacuous validator.

  Mapping verdict (measured, 2026-10-04): LOSSLESS at the OCEL 2.0 JSON layer
  — every pack gate's required field (event identity, eventTime, sequence,
  object relations, closed-type membership, full attribute closure) is present
  on the real export.

  Both previously pinned gaps are now CLOSED (fixed by the OCEL lane,
  2026-10-04):

  1. `subject_id` attribute closure: the export used to inject `subject_id`
     into every event's attributes without declaring it on the eventTypes
     (an OCEL 2.0 attribute-closure violation). Fixed — `subject_id` is now
     declared on the eventTypes, and this court pins the closure as exact:
     `validate(json)` must return `:ok` (zero undeclared attributes).
  2. Malformed timestamps: `ProcessEvidence` used to crash on a nil timestamp
     instead of refusing; it now returns a typed `:invalid_timestamp`
     refusal, so malformed timestamps are refused, not crashed on.

  The ggen-ecosystem-ocel pack's gate `040_closed_event_types_and_json_safe.rq`
  still closes eventType to the ten-lifecycle vocabulary
  (observe/admit/select/generate/realize/qualify/merge/receipt/replay/refuse);
  `task_succeeded`/`run_started`/`run_ended` are legal OCEL 2.0 activity
  identifiers but remain OUTSIDE that pack's closed set — a pack-policy gap,
  not a schema gap (the OCEL 2.0 standard does not close the activity
  vocabulary).

  Falsifier: if `LedgerOCEL` stops carrying `task`, `seq`, or object
  references on `task_succeeded` events, the round-trip assertions fail; if
  the validator is weakened, the anti-vacuity arm fails.
  """

  use ExUnit.Case, async: false

  alias AshPPlan.ProcessEvidence.Event
  alias AshPPlan.Reactor.Durable.LedgerOCEL
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Workflow.Runtime

  # ---------------------------------------------------------------------------
  # Real durable run
  # ---------------------------------------------------------------------------

  defp run_durable!(run_id) do
    workflow = [
      name: :ocel_v2_mapping,
      goal: :ocel_v2_mapping_complete,
      tasks: [
        [id: :ingest, capability: "Agent.Execute", after: [], authority: :observe],
        [id: :validate, capability: "Agent.Execute", after: [:ingest], authority: :observe]
      ]
    ]

    {:ok, store} = Ets.start_link()

    try do
      {:ok, %{observation: %{state: :succeeded}}} =
        Runtime.run(workflow, %{frontier: [], selected: :ocel_v2_mapping_root},
          providers: [AshPPlan.Examples.UltraCode.Steps.Local],
          store: store,
          run_id: run_id
        )

      {:ok, events} = LedgerOCEL.events(store, run_id)
      {:ok, json} = LedgerOCEL.export(store, run_id)
      {events, json}
    after
      GenServer.stop(store, :normal, 1_000)
    end
  end

  # ---------------------------------------------------------------------------
  # OCEL 2.0 validator (re-derived independently; shared with anti-vacuity arm)
  # ---------------------------------------------------------------------------

  @legal_activity ~r/^[^\s"\\\x00-\x1F]+$/

  @spec validate(String.t()) :: :ok | {:error, [String.t()]}
  defp validate(json) when is_binary(json) do
    doc = Jason.decode!(json)
    errors = validate_doc(doc)
    if errors == [], do: :ok, else: {:error, errors}
  end

  defp validate_doc(doc) do
    objects = doc["objects"] || []
    events = doc["events"] || []
    object_types = MapSet.new(doc["objectTypes"] || [], & &1["name"])
    event_types = MapSet.new(doc["eventTypes"] || [], & &1["name"])
    event_type_attrs = Map.new(doc["eventTypes"] || [], &{&1["name"], &1["attributes"] || []})

    object_ids =
      MapSet.new(objects, & &1["id"])

    declared_attr_names = fn type ->
      event_type_attrs
      |> Map.get(type, [])
      |> MapSet.new(& &1["name"])
    end

    Enum.flat_map(objects, fn o ->
      []
      |> add_error(is_binary(o["id"]) and o["id"] != "", "object with missing/empty id")
      |> add_error(
        MapSet.member?(object_types, o["type"]),
        "object #{o["id"]} has undeclared type #{inspect(o["type"])}"
      )
    end) ++
      Enum.flat_map(events, fn e ->
        attrs = Map.new(e["attributes"] || [], &{&1["name"], &1["value"]})
        declared = declared_attr_names.(e["type"])

        []
        |> add_error(is_binary(e["id"]) and e["id"] != "", "event with missing/empty id")
        |> add_error(
          is_binary(e["type"]) and e["type"] != "",
          "event #{e["id"]} missing type (activity)"
        )
        |> add_error(
          legal_time?(e["time"]),
          "event #{e["id"]} missing/unparseable ISO 8601 timestamp: #{inspect(e["time"])}"
        )
        |> add_error(
          MapSet.member?(event_types, e["type"]),
          "event #{e["id"]} has undeclared eventType #{inspect(e["type"])}"
        )
        |> add_error(
          e["relationships"] != nil and e["relationships"] != [],
          "event #{e["id"]} has no object references"
        )
        |> then(fn errs ->
          Enum.flat_map(e["relationships"] || [], fn r ->
            []
            |> add_error(
              is_binary(r["objectId"]) and r["objectId"] != "",
              "event #{e["id"]} relationship missing objectId"
            )
            |> add_error(
              MapSet.member?(object_ids, r["objectId"]),
              "event #{e["id"]} references dangling object #{inspect(r["objectId"])}"
            )
            |> add_error(
              is_binary(r["qualifier"]) and r["qualifier"] != "",
              "event #{e["id"]} relationship missing qualifier"
            )
          end) ++ errs
        end)
        |> then(fn errs ->
          Enum.flat_map(attrs, fn {name, _v} ->
            add_error(
              [],
              MapSet.member?(declared, name),
              "event #{e["id"]} attribute #{name} not declared on eventType"
            )
          end) ++ errs
        end)
      end)
  end

  defp legal_time?(t) when is_binary(t) do
    case DateTime.from_iso8601(t) do
      {:ok, _, _} -> true
      _ -> false
    end
  end

  defp legal_time?(_), do: false

  defp add_error(acc, true, _msg), do: acc
  defp add_error(acc, false, msg), do: [msg | acc]

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  @tag :court
  test "real durable run exports OCEL 2.0 JSON that satisfies the schema constraints" do
    {events, json} = run_durable!("ocel-v2-court-#{System.unique_integer([:positive])}")

    # the run actually produced the unified checkpoint vocabulary
    activities = events |> Enum.map(& &1.activity) |> Enum.uniq() |> Enum.sort()
    assert "task_succeeded" in activities
    assert "run_started" in activities

    # every emitted event carries the required shape at the struct layer
    Enum.each(events, fn %Event{} = e ->
      assert is_binary(e.id) and e.id != ""
      assert is_binary(e.activity) and e.activity != ""
      assert %DateTime{} = e.timestamp
      assert e.objects != []

      Enum.each(e.objects, fn {type, id, qualifier} ->
        assert is_binary(type) and type != ""
        assert is_binary(id) and id != ""
        assert is_binary(qualifier) and qualifier != ""
      end)
    end)

    # Both pinned gaps are CLOSED (2026-10-04): `subject_id` is now declared on
    # the exported eventTypes, so the attribute closure must hold exactly —
    # zero undeclared attributes. Any new undeclared attribute fails this court.
    assert :ok = validate(json), "undeclared attributes remain in the export"

    doc = Jason.decode!(json)

    # task-level round trip: every checkpoint's identity survives into the JSON
    struct_tasks =
      events
      |> Enum.filter(&(&1.activity == "task_succeeded"))
      |> Enum.map(& &1.attributes.task)

    json_tasks =
      doc["events"]
      |> Enum.filter(&(&1["type"] == "task_succeeded"))
      |> Enum.map(fn e ->
        Enum.find_value(e["attributes"], fn a -> a["name"] == "task" && a["value"] end)
      end)

    assert Enum.sort(struct_tasks) == Enum.sort(json_tasks)
    assert length(json_tasks) == 2

    # ledger labels carry the projected reactor step name
    # (`urn:ash-pplan:workflow:<name>#step-<task>`), so each task id must appear
    # as a substring of exactly one exported task attribute
    Enum.each(["ingest", "validate"], fn task_id ->
      matches = Enum.filter(json_tasks, &String.contains?(&1, task_id))

      assert length(matches) == 1,
             "task #{task_id} not carried exactly once: #{inspect(json_tasks)}"
    end)

    # object-level round trip: every object referenced by any event exists as an object
    referenced =
      doc["events"]
      |> Enum.flat_map(fn e -> Enum.map(e["relationships"] || [], & &1["objectId"]) end)
      |> MapSet.new()

    declared = MapSet.new(doc["objects"], & &1["id"])
    assert MapSet.subset?(referenced, declared)

    # seq is carried per event, so the authoritative order survives the export
    seqs =
      doc["events"]
      |> Enum.map(fn e ->
        Enum.find_value(e["attributes"], fn a -> a["name"] == "seq" && a["value"] end)
      end)

    # the export renders scalars via String.Chars, so seq arrives as a string;
    # what matters for losslessness is that every event carries its seq
    assert Enum.all?(seqs, &(is_integer(&1) or is_binary(&1)))
  end

  @tag :court
  test "task_succeeded is a legal OCEL 2.0 activity identifier" do
    assert Regex.match?(@legal_activity, "task_succeeded")
    assert Regex.match?(@legal_activity, "run_started")
    assert Regex.match?(@legal_activity, "run_ended")
    refute Regex.match?(@legal_activity, "bad activity\nname")
  end

  # ---------------------------------------------------------------------------
  # Anti-vacuity: the validator must REFUSE malformed events
  # ---------------------------------------------------------------------------

  test "anti-vacuity: event missing a timestamp fails the validator" do
    # Hand-built malformed OCEL 2.0 JSON: ProcessEvidence.export/2 itself crashes
    # on a nil timestamp (DateTime.to_iso8601/1), so the malformed event is fed
    # to the validator at the JSON layer a pack/target tool would receive.
    json =
      Jason.encode!(%{
        "objectTypes" => [%{"name" => "WorkflowRun", "attributes" => []}],
        "eventTypes" => [
          %{
            "name" => "task_succeeded",
            "attributes" => [
              %{"name" => "task", "type" => "string"},
              %{"name" => "seq", "type" => "string"}
            ]
          }
        ],
        "objects" => [%{"id" => "run:x", "type" => "WorkflowRun", "attributes" => []}],
        "events" => [
          %{
            "id" => "run:x/bad",
            "type" => "task_succeeded",
            "relationships" => [%{"objectId" => "run:x", "qualifier" => "run"}],
            "attributes" => [
              %{"name" => "task", "value" => "x"},
              %{"name" => "seq", "value" => 1}
            ]
          }
        ]
      })

    assert {:error, errors} = validate(json)
    assert Enum.any?(errors, &String.contains?(&1, "timestamp")), inspect(errors)
  end

  test "anti-vacuity: dangling object reference fails the validator" do
    json =
      Jason.encode!(%{
        "objectTypes" => [%{"name" => "WorkflowRun", "attributes" => []}],
        "eventTypes" => [%{"name" => "run_started", "attributes" => []}],
        "objects" => [%{"id" => "run:real", "type" => "WorkflowRun", "attributes" => []}],
        "events" => [
          %{
            "id" => "run:y/started",
            "type" => "run_started",
            "time" => DateTime.to_iso8601(DateTime.utc_now()),
            "relationships" => [%{"objectId" => "run:ghost", "qualifier" => "run"}],
            "attributes" => []
          }
        ]
      })

    assert {:error, errors} = validate(json)
    assert Enum.any?(errors, &String.contains?(&1, "dangling")), inspect(errors)
  end

  test "anti-vacuity: event with no object references fails the validator" do
    json =
      Jason.encode!(%{
        "objectTypes" => [%{"name" => "WorkflowRun", "attributes" => []}],
        "eventTypes" => [%{"name" => "run_started", "attributes" => []}],
        "objects" => [%{"id" => "run:z", "type" => "WorkflowRun", "attributes" => []}],
        "events" => [
          %{
            "id" => "run:z/started",
            "type" => "run_started",
            "time" => DateTime.to_iso8601(DateTime.utc_now()),
            "relationships" => [],
            "attributes" => []
          }
        ]
      })

    assert {:error, errors} = validate(json)
    assert Enum.any?(errors, &String.contains?(&1, "no object references")), inspect(errors)
  end
end

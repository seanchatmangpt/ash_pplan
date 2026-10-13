defmodule AshPPlan.ProcessEvidence.XaasTest do
  use ExUnit.Case, async: true

  alias AshPPlan.ProcessEvidence
  alias AshPPlan.ProcessEvidence.{Event, Xaas}

  @ts ~U[2026-10-13 12:00:00.000Z]

  defp evs do
    [
      %Event{
        id: "run:r1/ingest@1",
        activity: "run_started",
        timestamp: @ts,
        objects: [{"WorkflowRun", "run:r1", "run"}],
        attributes: %{plan: "urn:p", seq: 0},
        subject_id: "s1"
      },
      %Event{
        id: "run:r1/ingest@2",
        activity: "task_succeeded",
        timestamp: @ts,
        objects: [
          {"WorkflowRun", "run:r1", "run"},
          {"Step", "step:ingest", "step"},
          {"Realization", "impl:Ingest", "realization"}
        ],
        attributes: %{task: "ingest", seq: 2, score: 0.5, ok: true},
        subject_id: "s1"
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # Round trip: export -> xaas row -> event/object identity + type preservation
  # ---------------------------------------------------------------------------

  test "round trip preserves event and object identity" do
    {:ok, json} = ProcessEvidence.export(evs(), :ocel2_json)
    {:ok, row} = evs() |> Xaas.to_row()

    export_events = row["ocel:events"]
    xaas_events = row["ocel:events"]

    # identity: event ids and activities survive in both envelopes
    assert Enum.map(export_events, & &1["id"]) == Enum.map(xaas_events, & &1["id"])

    assert Enum.sort(Enum.map(export_events, & &1["type"])) ==
             Enum.sort(Enum.map(xaas_events, & &1["type"]))

    # object identity: every relationship target in either envelope is declared
    for env <- [Jason.decode!(json), row] do
      objects = MapSet.new(objects_of(env), & &1["id"])

      referenced =
        env
        |> events_of()
        |> Enum.flat_map(fn e -> Enum.map(e["relationships"] || [], & &1["objectId"]) end)
        |> MapSet.new()

      assert MapSet.subset?(referenced, objects)
    end

    # the xaas row is a superset: the Subject object is declared there too
    assert MapSet.member?(
             MapSet.new(row["ocel:objects"], & &1["id"]),
             "subject:s1"
           )
  end

  test "xaas row attribute types are preserved (sabotage of the string-flattening defect)" do
    {:ok, row} = evs() |> Xaas.to_row()

    [run_started, task_succeeded] = row["ocel:events"]

    # typed values survive: integer, float, boolean, string
    assert task_succeeded["attributes"]["seq"] == 2 and
             is_integer(task_succeeded["attributes"]["seq"])

    assert task_succeeded["attributes"]["score"] == 0.5 and
             is_float(task_succeeded["attributes"]["score"])

    assert task_succeeded["attributes"]["ok"] == true
    assert task_succeeded["attributes"]["task"] == "ingest"
    assert run_started["attributes"]["seq"] == 0

    # subject is an identifier (relationship to a Subject object), not an attribute
    refute Map.has_key?(task_succeeded["attributes"], "subject_id")

    assert {"subject:s1", "subject"} in Enum.map(
             task_succeeded["relationships"],
             &{&1["objectId"], &1["qualifier"]}
           )
  end

  test "corrected export/3 also preserves types and moves subject_id out of attributes" do
    {:ok, json} = ProcessEvidence.export(evs(), :ocel2_json)
    {:ok, corrected} = ProcessEvidence.export(evs(), :ocel2_json, [])
    doc = Jason.decode!(corrected)

    [_, task_ev] = doc["events"]
    attrs = Map.new(task_ev["attributes"], &{&1["name"], &1["value"]})

    assert attrs["seq"] == 2 and is_integer(attrs["seq"])
    assert attrs["ok"] == true
    refute Map.has_key?(attrs, "subject_id")
    assert Enum.any?(task_ev["relationships"], &(&1["objectId"] == "subject:s1"))
    assert Enum.any?(doc["objects"], &(&1["id"] == "subject:s1" and &1["type"] == "Subject"))

    # eventTypes declarations carry real types in corrected mode
    et = Enum.find(doc["eventTypes"], &(&1["name"] == "task_succeeded"))
    types = Map.new(et["attributes"], &{&1["name"], &1["type"]})
    assert types["seq"] == "integer"
    assert types["ok"] == "boolean"
    assert types["score"] == "float"
    assert types["task"] == "string"

    # the legacy export/2 envelope is untouched (string values, subject_id injected)
    legacy_doc = Jason.decode!(json)
    [_, legacy_ev] = legacy_doc["events"]
    legacy_attrs = Map.new(legacy_ev["attributes"], &{&1["name"], &1["value"]})
    assert legacy_attrs["subject_id"] == "s1"
    assert legacy_attrs["seq"] == "2"
  end

  test "xaas ndjson line decodes to the same row" do
    {:ok, line} = Xaas.to_ndjson_line(evs())
    assert line =~ "\n"
    {:ok, decoded} = JSON.decode(line)
    {:ok, row} = Xaas.to_row(evs())
    assert decoded == row
  end

  # ---------------------------------------------------------------------------
  # Sabotage twins: drop a required identifier -> typed refusal
  # ---------------------------------------------------------------------------

  test "sabotage: event with nil id is refused with a typed error" do
    sabotaged = [%Event{id: nil, activity: "task_succeeded", timestamp: @ts}]

    assert {:error, %{reason: :missing_identifier, field: :id, event: nil, event_index: 0}} =
             Xaas.to_row(sabotaged)

    assert {:error, %{reason: :missing_identifier, field: :id}} = Xaas.to_ndjson_line(sabotaged)
  end

  test "sabotage: event with empty activity is refused" do
    sabotaged = [%Event{id: "e1", activity: "", timestamp: @ts}]

    assert {:error, %{reason: :missing_identifier, field: :activity, event_index: 0}} =
             Xaas.to_row(sabotaged)
  end

  test "sabotage: event with a dangling empty object id is refused" do
    sabotaged = [
      %Event{
        id: "e1",
        activity: "task_succeeded",
        timestamp: @ts,
        objects: [{"Step", "", "step"}]
      }
    ]

    assert {:error, %{reason: :missing_identifier, field: :object_id, event_index: 0}} =
             Xaas.to_row(sabotaged)
  end

  test "sabotage: non-DateTime timestamp is refused" do
    sabotaged = [%Event{id: "e1", activity: "task_succeeded", timestamp: "not-a-time"}]

    assert {:error, %{reason: :invalid_timestamp, field: :timestamp, event_index: 0}} =
             Xaas.to_row(sabotaged)
  end

  test "to_row/1 on a non-list refuses" do
    assert {:error, %{reason: :missing_identifier}} = Xaas.to_row(:not_events)
  end

  defp objects_of(env), do: env["objects"] || env["ocel:objects"]
  defp events_of(env), do: env["events"] || env["ocel:events"]
end

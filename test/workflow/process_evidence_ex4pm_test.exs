defmodule AshPPlan.ProcessEvidenceEx4pmTest do
  use ExUnit.Case, async: true

  alias AshPPlan.ProcessEvidence.Event
  alias AshPPlan.ProcessEvidence.Ex4pm, as: Adapter

  @unsupported {:error, %{reason: :unsupported, detail: :ex4pm_not_available}}

  defp sample do
    [
      %Event{
        id: "e1",
        activity: "task_attempted",
        timestamp: ~U[2026-09-30 00:00:00Z],
        objects: [{"WorkflowRun", "run:1", "run"}, {"Task", "task:t", "target"}],
        attributes: %{task: "t"},
        subject_id: "s"
      },
      %Event{
        id: "e2",
        activity: "task_succeeded",
        timestamp: ~U[2026-09-30 00:00:05Z],
        objects: [{"WorkflowRun", "run:1", "run"}],
        attributes: %{},
        subject_id: "s"
      }
    ]
  end

  if Code.ensure_loaded?(Elixir.Ex4pm.Event) do
    test "maps to Ex4pm structs" do
      assert Adapter.available?()

      assert {:ok, [%Elixir.Ex4pm.Event{id: "e1"} = ev, %Elixir.Ex4pm.Event{id: "e2"}]} =
               Adapter.to_events(sample())

      assert [%Elixir.Ex4pm.EventRelationship{object_id: "run:1", qualifier: "run"}, _] =
               ev.relationships
    end

    test "event log carries objects" do
      assert {:ok, %Elixir.Ex4pm.EventLog{objects: objs, events: evs}} =
               Adapter.to_event_log(sample())

      assert Map.keys(objs) |> Enum.sort() == ["run:1", "task:t"]
      assert length(evs) == 2
    end

    test "round trip: events -> EventLog -> OCEL2 JSON -> Ex4pm reader" do
      assert {:ok, json} = Adapter.export(sample(), :ocel2_json)
      assert {:ok, %Elixir.Ex4pm.EventLog{} = log} = Adapter.parse(json)
      assert Enum.map(log.events, & &1.id) == ["e1", "e2"]
      assert Enum.map(log.events, & &1.activity) == ["task_attempted", "task_succeeded"]
      assert Map.keys(log.objects) |> Enum.sort() == ["run:1", "task:t"]
      assert log.objects["task:t"].type == "Task"
      [e1, _] = log.events
      assert e1.object_ids == ["run:1", "task:t"]
      assert Enum.any?(e1.relationships, &(&1.object_id == "task:t" and &1.qualifier == "target"))
    end

    test "export agrees with the local pure OCEL2 export on object/event ids" do
      {:ok, a} = Adapter.export(sample(), :ocel2_json)
      {:ok, b} = AshPPlan.ProcessEvidence.export(sample(), :ocel2_json)

      ids = fn j ->
        j
        |> Jason.decode!()
        |> then(
          &{Enum.map(&1["events"], fn e -> e["id"] end),
           Enum.map(&1["objects"], fn o -> o["id"] end)}
        )
      end

      {ea, oa} = ids.(a)
      {eb, ob} = ids.(b)
      assert ea == eb
      assert Enum.sort(oa) == Enum.sort(ob)
    end

    test "unknown format is refused" do
      assert {:error, %{reason: :unsupported_format}} = Adapter.export(sample(), :xes)
    end
  end

  test "available?: false yields UNSUPPORTED on every call" do
    off = [available?: false]
    assert Adapter.to_events(sample(), off) == @unsupported
    assert Adapter.to_event_log(sample(), off) == @unsupported
    assert Adapter.export(sample(), :ocel2_json, off) == @unsupported
    assert Adapter.parse("{}", off) == @unsupported
    assert Adapter.events(:run) == @unsupported
  end
end

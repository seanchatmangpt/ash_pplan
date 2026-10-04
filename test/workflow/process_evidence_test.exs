defmodule AshPPlan.ProcessEvidenceTest do
  use ExUnit.Case, async: true

  alias AshPPlan.ProcessEvidence
  alias AshPPlan.Workflow.Runtime
  alias AshPPlan.Examples.UltraCode.Steps

  @frontier [%{id: :a, status: :open, deps: []}, %{id: :b, status: :open, deps: [:a]}]

  test "real run receipt becomes attempted/succeeded pairs exported as OCEL 2 JSON" do
    {:ok, s} = Runtime.run(Steps.workflow(), %{frontier: @frontier}, providers: [Steps.Local])
    assert s.observation.state == :succeeded
    reals = Map.new(s.resolutions, fn {k, v} -> {k, inspect(v.provider)} end)

    evs =
      ProcessEvidence.events_from_receipt(s.evidence.receipt, s.subject,
        tasks: s.model.tasks,
        realizations: reals
      )

    assert length(evs) == 2 * length(s.model.tasks)
    assert Enum.all?(evs, &(&1.subject_id == s.subject.id))

    assert {:ok, json} = ProcessEvidence.export(evs, :ocel2_json)
    doc = Jason.decode!(json)
    assert Enum.sort(Map.keys(doc)) == ["eventTypes", "events", "objectTypes", "objects"]
    assert length(doc["events"]) == length(evs)

    assert Enum.map(doc["objectTypes"], & &1["name"]) == [
             "Capability",
             "Realization",
             "WorkflowRun"
           ]

    assert Enum.all?(doc["events"], fn e -> length(e["relationships"]) == 3 end)
  end

  test "failed run emits failed event and stops" do
    {:ok, s} =
      Runtime.run(Steps.workflow(), %{frontier: @frontier}, providers: [Steps.Flaky, Steps.Local])

    evs =
      ProcessEvidence.events_from_receipt(s.evidence.receipt, s.subject,
        tasks: s.model.tasks,
        failed_task: s.observation.failed_task
      )

    assert Enum.any?(evs, &(&1.activity == "task_failed"))
    refute Enum.any?(evs, &(&1.activity == "task_succeeded" and &1.attributes.task == "execute"))
  end

  test "unsupported format is a typed refusal" do
    assert {:error, %{reason: :unsupported_format}} = ProcessEvidence.export([], :xes)
  end

  test "nil timestamp is a typed refusal, not a raise" do
    ev = %ProcessEvidence.Event{
      id: "e1",
      activity: "task_attempted",
      timestamp: nil,
      objects: [{"WorkflowRun", "run:1", "run"}],
      attributes: %{task: "t"},
      subject_id: "s1"
    }

    assert {:error, %{reason: :invalid_timestamp, event: "e1"}} =
             ProcessEvidence.export([ev], :ocel2_json)
  end

  test "export declares every emitted event attribute (zero undeclared)" do
    {:ok, s} = Runtime.run(Steps.workflow(), %{frontier: @frontier}, providers: [Steps.Local])
    reals = Map.new(s.resolutions, fn {k, v} -> {k, inspect(v.provider)} end)

    evs =
      ProcessEvidence.events_from_receipt(s.evidence.receipt, s.subject,
        tasks: s.model.tasks,
        realizations: reals
      )

    assert {:ok, json} = ProcessEvidence.export(evs, :ocel2_json)
    doc = Jason.decode!(json)

    declared =
      Map.new(doc["eventTypes"], fn t ->
        {t["name"], MapSet.new(t["attributes"], & &1["name"])}
      end)

    undeclared =
      Enum.flat_map(doc["events"], fn e ->
        declared_names = MapSet.new(Map.get(declared, e["type"], []))

        for a <- e["attributes"] || [],
            not MapSet.member?(declared_names, a["name"]),
            do: {e["id"], a["name"]}
      end)

    assert undeclared == [], inspect(undeclared)
  end
end

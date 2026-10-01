defmodule AshPPlan.ProcessEvidenceEx4pmTest do
  use ExUnit.Case, async: true

  alias AshPPlan.ProcessEvidence.{Event, Ex4pm}

  @unsupported {:error, %{reason: :unsupported, detail: :ex4pm_not_available}}

  defp sample do
    [
      %Event{
        id: "e1",
        activity: "task_attempted",
        timestamp: ~U[2026-09-30 00:00:00Z],
        objects: [{"WorkflowRun", "run:1", "run"}],
        attributes: %{task: "t"},
        subject_id: "s"
      }
    ]
  end

  if Code.ensure_loaded?(Ex4pm.Event) do
    @tag :ex4pm_present
    test "maps to Ex4pm structs" do
      assert {:ok, [%{__struct__: Ex4pm.Event, id: "e1"}]} = Ex4pm.to_events(sample())
    end
  else
    # Ex4pm is not a dep and cannot be prepended into the code path here: real mapping is
    # UNSUPPORTED/skipped until the dep is added to mix.exs.
    @tag skip: "ex4pm not available (UNSUPPORTED until dep added)"
    test "maps to Ex4pm structs" do
    end

    test "every call returns unsupported" do
      refute Ex4pm.available?()
      assert Ex4pm.to_events(sample()) == @unsupported
      assert Ex4pm.to_event_log(sample()) == @unsupported
      assert Ex4pm.export(sample(), :ocel2_json) == @unsupported
      assert Ex4pm.events(:run) == @unsupported
    end
  end
end

defmodule AshPPlan.ProcessEvidenceAshEx4pmTest do
  use ExUnit.Case, async: true

  alias AshPPlan.ProcessEvidence.{AshEx4pm, Event}

  defp events do
    [
      %Event{
        id: "e1",
        activity: "task_attempted",
        timestamp: ~U[2026-09-30 00:00:00Z],
        objects: [{"WorkflowRun", "run:1", "run"}],
        attributes: %{task: "t"},
        subject_id: nil
      }
    ]
  end

  defp ctx do
    [
      subject: %{
        id: "sha256:abc",
        workflow: "wf",
        digest: "abc",
        correspondence: %{t: AshPPlan.Workflow.Subject.correspondence("wf", :t)}
      },
      task: :t,
      realization: %AshPPlan.Realization{
        capability: "File.Write",
        provider: :file,
        binding: %{adapter: :reactor_file, op: :file_write}
      },
      authority: :construct,
      evidence: %{receipt: "r1"}
    ]
  end

  test "envelope carries subject, task, realization, authority (pure)" do
    env = AshEx4pm.envelope(events(), ctx())
    assert env["schema"] == "ash_ex4pm/1"
    assert %{"type" => "WorkflowSubject"} = env["objects"]["sha256:abc"]
    assert env["objects"]["task:sha256:abc:t"]["type"] == "WorkflowTask"

    assert env["objects"]["realization:File.Write:file:file_write"]["attributes"]["adapter"] ==
             "reactor_file"

    [ev] = env["events"]
    assert ev["attributes"]["authority"] == "construct"
    assert ev["attributes"]["subject_id"] == "sha256:abc"
    assert length(ev["relationships"]) == 4
  end

  test "real Ex4pm.OCEL.validate_envelope admits it, or typed UNSUPPORTED when deps absent" do
    case AshEx4pm.validate(events(), ctx()) do
      {:ok, _} -> assert AshEx4pm.ex4pm_available?()
      {:error, e} -> assert e == %{reason: :unsupported, detail: :ex4pm_not_available}
    end
  end

  test "real Ingest.ingest_envelope ingests it" do
    if AshEx4pm.ex4pm_available?() do
      {:ok, store} = start_supervised({Ex4pm.Evidence.Store, [name: :ash_ex4pm_t_store]})
      {:ok, miner} = start_supervised({Ex4pm.Engine.OnlineMiner, [name: :ash_ex4pm_t_miner]})

      assert {:ok, r} =
               AshEx4pm.ingest(events(), [{:ingest_opts, [store: store, miner: miner]} | ctx()])

      assert r.status == :ingested
    else
      assert {:error, %{reason: :unsupported}} = AshEx4pm.ingest(events(), ctx())
    end
  end

  test "activities/1 reads AshEx4pm.Info from a real declared resource, or typed UNSUPPORTED" do
    if AshEx4pm.available?() do
      Code.eval_string("""
      defmodule AshPPlan.Test.Ex4pmThing do
        use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, extensions: [AshEx4pm]
        ex4pm do
          activity :thing_created, on: :create
        end
        attributes do
          uuid_primary_key :id
        end
        actions do
          defaults [:read]
          create :create
        end
      end
      """)

      assert {:ok, [%{name: :thing_created, on: :create}]} =
               AshEx4pm.activities(AshPPlan.Test.Ex4pmThing)

      assert {:error, %{reason: :not_an_ex4pm_resource}} =
               AshEx4pm.activities(AshPPlan.Realization)
    else
      assert {:error, %{reason: :unsupported}} = AshEx4pm.activities(AshPPlan.Realization)
    end
  end
end

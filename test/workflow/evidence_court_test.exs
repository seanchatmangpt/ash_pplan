defmodule AshPPlan.Workflow.EvidenceCourtTest do
  @moduledoc """
  Evidence Court. Falsifies: a workflow run that yields no PROV, OCEL,
  telemetry or receipt evidence, or evidence not bound to the workflow
  subject id. Anti-vacuity mutations: dropping a kind, rebinding to another
  subject, and tampering the PROV text must each be detected by `verify/2`.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Workflow.{Evidence, Model, Subject}

  defp model(name \\ :court_wf) do
    {:ok, m} =
      Model.new(
        name: name,
        tasks: [
          [id: :observe, capability: "Repository.Observe", outcomes: [:ok], evidence: [:receipt]],
          [id: :select, capability: "Work.Select", after: [:observe], outcomes: [:ok]]
        ]
      )

    m
  end

  test "profile requires all four kinds and lists task evidence" do
    p = Evidence.profile(model())
    assert p.required == [:prov, :ocel, :telemetry, :receipt]
    assert p.tasks.observe == [:receipt]
    assert p.subject == Subject.bind(model()).id
  end

  test "bind produces all evidence kinds bound to the subject id" do
    subject = Subject.bind(model())
    {:ok, ev} = Evidence.bind(subject, run_id: "r1", outcome: {:ok, %{a: 1}})

    assert :ok = Evidence.verify(ev, subject.id)
    assert ev.receipt.status == :succeeded
    assert ev.prov =~ "https://w3id.org/ash-pplan#ExecutionReceipt"
    assert ev.prov =~ Evidence.plan_iri(subject.id)
    assert ev.ocel.attributes.subject_id == subject.id
    assert {[:ash_pplan, :workflow, :run], %{duration_us: _}, %{subject_id: sid}} = ev.telemetry
    assert sid == subject.id
  end

  test "bind accepts a model directly and failed outcomes still bind" do
    {:ok, ev} = Evidence.bind(model(), run_id: 7, outcome: {:error, :boom})
    assert ev.receipt.status == :failed
    assert :ok = Evidence.verify(ev, ev.subject_id)
  end

  test "telemetry is really emitted when requested" do
    ref = make_ref()
    me = self()
    id = "evidence-court-#{inspect(ref)}"

    :telemetry.attach(
      id,
      Evidence.telemetry_event(),
      fn _e, m, meta, _ -> send(me, {ref, m, meta}) end,
      nil
    )

    # Pin the receive to this run's subject: telemetry is a process-wide
    # broadcast (the reactor evidence middleware emits with `emit: true` for
    # every reactor run), so a globally-attached handler in an async test
    # otherwise matches a foreign subject's event.
    subject = Subject.bind(model())

    {:ok, ev} = Evidence.bind(subject, run_id: "emit", emit: true)
    :telemetry.detach(id)
    sid = subject.id
    assert_receive {^ref, %{duration_us: _}, %{subject_id: ^sid}}
    assert sid == ev.subject_id
  end

  test "different workflows get different bound evidence" do
    {:ok, a} = Evidence.bind(model(:one), run_id: "r")
    {:ok, b} = Evidence.bind(model(:two), run_id: "r")
    refute a.subject_id == b.subject_id
    assert {:error, %{reason: :subject_mismatch}} = Evidence.verify(a, b.subject_id)
  end

  test "bind refuses an unbound subject" do
    assert {:error, %{reason: :unbound_subject}} = Evidence.bind(%{id: "nope"})
  end

  describe "mutations (anti-vacuity)" do
    setup do
      {:ok, ev} = Evidence.bind(model(), run_id: "m")
      %{ev: ev}
    end

    test "dropping any kind is detected", %{ev: ev} do
      for kind <- Evidence.kinds() do
        assert {:error, %{reason: :missing_evidence, kinds: [^kind]}} =
                 Evidence.verify(Map.put(ev, kind, nil), ev.subject_id)
      end
    end

    test "PROV rebound to another plan is detected", %{ev: ev} do
      other = Evidence.plan_iri("sha256:" <> String.duplicate("0", 64))
      tampered = String.replace(ev.prov, Evidence.plan_iri(ev.subject_id), other)

      assert {:error, %{reason: :unbound_evidence, kinds: [:prov]}} =
               Evidence.verify(%{ev | prov: tampered}, ev.subject_id)
    end

    test "OCEL and telemetry with a foreign subject are detected", %{ev: ev} do
      ocel = put_in(ev.ocel, [:attributes, :subject_id], "sha256:x")
      {name, meas, meta} = ev.telemetry
      tele = {name, meas, %{meta | subject_id: "sha256:x"}}

      assert {:error, %{reason: :unbound_evidence, kinds: kinds}} =
               Evidence.verify(%{ev | ocel: ocel, telemetry: tele}, ev.subject_id)

      assert kinds == [:ocel, :telemetry]
    end

    test "receipt for another plan is detected", %{ev: ev} do
      bad = %{ev.receipt | plan_iri: "urn:other"}

      assert {:error, %{reason: :unbound_evidence, kinds: [:receipt]}} =
               Evidence.verify(%{ev | receipt: bad}, ev.subject_id)
    end
  end
end

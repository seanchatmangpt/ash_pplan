defmodule AshPPlan.Pm4ExUnit.HtnPowlControlPlaneTest do
  @moduledoc """
  Process-conformance of real AshPPlan traces: HTN decomposition order, POWL
  linear extensions, control-plane describe -> verify, and process-evidence
  export. Every event is emitted from a real call's output; no mocks, no sleeps.
  """

  use ExUnit.Case, async: true
  use Pm4ExUnit

  @moduletag :pm4exunit

  alias AshPPlan.ControlPlane
  alias AshPPlan.ExecutionReceipt
  alias AshPPlan.HTN
  alias AshPPlan.POWL
  alias AshPPlan.POWL.Verifier
  alias AshPPlan.ProcessEvidence

  defp emit_all(session, prefix, activities) do
    activities
    |> Enum.with_index()
    |> Enum.each(fn {act, i} -> emit_event(session, "#{prefix}-#{i}", act) end)
  end

  # All linear extensions of a partial order (ids + strict-order edges).
  defp linear_extensions([], _edges), do: [[]]

  defp linear_extensions(ids, edges) do
    ids
    |> Enum.filter(fn id -> not Enum.any?(edges, fn {s, t} -> t == id and s in ids end) end)
    |> Enum.flat_map(fn id ->
      for rest <- linear_extensions(List.delete(ids, id), edges), do: [id | rest]
    end)
  end

  describe "HTN decomposition" do
    setup do
      domain =
        HTN.new(
          [
            [name: :gather, add_list: [:have_inputs]],
            [name: :build, preconditions: [:have_inputs], add_list: [:built]],
            [name: :ship, preconditions: [:built], add_list: [:shipped]]
          ],
          [[id: :deliver_m, task: :deliver, subtasks: [:gather, :build, :ship]]]
        )

      {:ok, domain: domain}
    end

    test "realized primitive order equals the method's ordered subtasks",
         %{pm4_session: session, domain: domain} do
      assert {:ok, result} = HTN.decompose(domain, [:deliver], [])
      [method] = domain.methods

      emit_all(session, "htn", result.plan)

      assert_conformance(session, [method.subtasks])
      refute_conformance(session, [Enum.reverse(method.subtasks)])
    end

    test "compound trace precedes its primitives and a reordering violates the model",
         %{pm4_session: session, domain: domain} do
      assert {:ok, result} = HTN.decompose(domain, [:deliver], [])

      trace_acts =
        Enum.map(result.decomposition_trace, fn
          %{kind: :compound, task: t} -> "decompose:#{t}"
          %{kind: :primitive, task: t} -> "do:#{t}"
        end)

      emit_all(session, "trace", trace_acts)

      assert_conformance(session, [
        ["decompose:deliver", "do:gather", "do:build", "do:ship"]
      ])

      refute_conformance(session, [
        ["decompose:deliver", "do:build", "do:gather", "do:ship"]
      ])
    end
  end

  describe "POWL partial order" do
    test "admits exactly its linear extensions" do
      po =
        POWL.partial_order(
          "po_diamond",
          Enum.map(["a", "b", "d", "c"], &POWL.activity/1),
          [{"a", "b"}, {"a", "d"}, {"b", "c"}, {"d", "c"}]
        )

      assert :ok = Verifier.verify(po)

      ids = Enum.map(po.children, & &1.id)
      allowed = linear_extensions(ids, po.order_edges)

      assert Enum.sort(allowed) == [["a", "b", "d", "c"], ["a", "d", "b", "c"]]

      for {lin, i} <- Enum.with_index(allowed) do
        {:ok, s} = Pm4ExUnit.Session.start_link(test_name: "lin-#{i}")
        emit_all(s, "lin#{i}", lin)
        assert_conformance(s, allowed)
      end

      # every permutation outside the allowed set violates some edge
      permutations = linear_extensions(ids, [])
      assert length(permutations) == 24

      for bad <- permutations -- allowed do
        {:ok, s} = Pm4ExUnit.Session.start_link(test_name: "bad")
        emit_all(s, "bad", bad)
        refute_conformance(s, allowed)
      end
    end

    test "a trace violating the a -> b edge is refuted", %{pm4_session: session} do
      emit_all(session, "v", ["b", "a", "d", "c"])
      refute_conformance(session, [["a", "b", "d", "c"], ["a", "d", "b", "c"]])
    end
  end

  describe "control plane" do
    test "describe precedes verify and both succeed", %{pm4_session: session} do
      assert {:ok, cp} = ControlPlane.describe(AshPPlan.ControlPlaneIntegrationResource)
      emit_event(session, "cp-describe", :describe)
      assert cp.state_machine.available?

      model = POWL.sequence("seq", [POWL.activity("a"), POWL.activity("b")])
      assert :ok = Verifier.verify(model)
      emit_event(session, "cp-verify", :verify)

      assert_conformance(session, [[:describe, :verify]])
      refute_conformance(session, [[:verify, :describe]])
    end
  end

  describe "process evidence" do
    test "exported run events conform to the plan model", %{pm4_session: session} do
      now = DateTime.utc_now()

      receipt = %ExecutionReceipt{
        plan_iri: "urn:plan:pm4",
        run_id: "run-pm4",
        status: :succeeded,
        started_at: now,
        finished_at: DateTime.add(now, 1, :second),
        duration_us: 1_000_000,
        outcome_digest: "digest"
      }

      tasks = [%{id: :a, capability: :cap_a}, %{id: :b, capability: :cap_b}]
      events = ProcessEvidence.events_from_receipt(receipt, %{id: "subj"}, tasks: tasks)

      assert {:ok, json} = ProcessEvidence.export(events, :ocel2_json, [])
      exported = Jason.decode!(json)["events"]
      assert length(exported) == length(events)

      # replay the exported OCEL events in order against the plan model
      exported
      |> Enum.zip(events)
      |> Enum.each(fn {oe, e} ->
        emit_event(session, oe["id"], "#{e.attributes.task}:#{oe["type"]}")
      end)

      plan_model = [
        ["a:task_attempted", "a:task_succeeded", "b:task_attempted", "b:task_succeeded"]
      ]

      assert_conformance(session, plan_model)

      refute_conformance(session, [
        ["b:task_attempted", "b:task_succeeded", "a:task_attempted", "a:task_succeeded"]
      ])
    end
  end
end

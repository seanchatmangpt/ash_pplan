defmodule AshPPlan.Reactor.Durable.SemanticRealityOcelCourtTest do
  @moduledoc """
  Court: the evidence-export semantics of `AshPPlan.Reactor.Durable.LedgerOCEL` over a
  *real* durable run of the workflow `Runtime` facade (real Reactor, real `Store.Ets`).

  Pins four semantic facts:

  1. `events/3` carries the p-plan `Step`-ordered checkpoints: one `task_succeeded` event
     per standing checkpoint, in ascending ledger `seq` order, each bound to a `Step` object.
  2. `export/3` produces OCEL 2.0 JSON (`objectTypes`/`eventTypes`/`objects`/`events`)
     that actually parses.
  3. `digest/3` is stable across two calls on the same store state.
  4. The digest is tamper-evident: undo a standing checkpoint's output and the digest moves.

  Anti-vacuity: the export JSON parses and `length(events) == tape length + run lifecycle
  events` (`run_started` always, `run_ended` iff terminal). Mutations that would vacate
  this: dropping the `Step` object from task events, or dropping the terminal `run_ended`
  event, both flip explicit assertions here.
  """

  use ExUnit.Case, async: false

  alias AshPPlan.Providers.DurableGate
  alias AshPPlan.Examples.UltraCode.Steps
  alias AshPPlan.Reactor.Durable.{Clock, LedgerOCEL}
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Workflow.Runtime

  @frontier [%{id: :a, status: :open, deps: []}, %{id: :b, status: :open, deps: [:a]}]

  setup do
    Clock.use_test_clock()
    on_exit(&Clock.reset/0)
    {:ok, store} = Ets.start_link()
    {:ok, store: store}
  end

  defp gated do
    base = Steps.workflow()

    tasks =
      Enum.map(base[:tasks], fn t ->
        if t[:id] == :execute, do: Keyword.put(t, :after, [:select, :gate]), else: t
      end)

    gate = [id: :gate, capability: "Human.Approve", after: [:select], authority: :observe]
    Keyword.put(base, :tasks, List.insert_at(tasks, 2, gate))
  end

  # Real durable run through the Runtime facade: parks on the human gate (checkpoints on
  # the tape), then completes after the release signal. Returns the halted-phase tape and
  # the final state.
  defp run_to_completion(store, run_id) do
    providers = [Steps.Local, DurableGate]

    assert {:ok, s1} =
             Runtime.run(gated(), %{frontier: @frontier},
               providers: providers,
               store: store,
               run_id: run_id
             )

    assert s1.observation.state == :halted

    {:ok, explain} = Runtime.explain(s1)
    tape = explain.durable.checkpoints
    assert is_list(tape) and tape != []

    [wait] = explain.durable.waiting_on
    assert {:ok, final} = Runtime.resume(s1, signal: {wait, %{released: true}})
    assert final.observation.state == :succeeded

    {tape, final}
  end

  test "events carry p-plan Step-ordered checkpoints; count == tape + lifecycle", %{store: store} do
    {halted_tape, final} = run_to_completion(store, "sroc-1")
    assert {:ok, final_explain} = Runtime.explain(final)
    tape_len = length(final_explain.durable.checkpoints)
    assert tape_len > length(halted_tape)

    assert {:ok, events} = LedgerOCEL.events(store, "sroc-1")

    # lifecycle: run_started always, run_ended only because the run is terminal
    assert [%{activity: "run_started", attributes: %{seq: 0}} | _] = events

    assert {_, [%{activity: "run_ended", attributes: %{status: "completed"}}]} =
             Enum.split(events, -1)

    steps = Enum.filter(events, &(&1.activity == "task_succeeded"))
    assert length(steps) == tape_len
    assert length(events) == tape_len + 2

    # p-plan Step ordering: seq attributes strictly ascending, one Step object per event
    seqs = Enum.map(steps, & &1.attributes.seq)
    assert seqs == Enum.sort(Enum.uniq(seqs))

    Enum.each(steps, fn e ->
      assert {_, _, "step"} = Enum.find(e.objects, fn {_t, _id, role} -> role == "step" end)
      assert e.attributes[:output_digest] =~ ~r/^[0-9a-f]{64}$/
      assert is_binary(e.attributes[:task])
    end)

    # started (seq 0) < first step < ... < last step < ended (max seq + 1)
    assert hd(steps).attributes.seq > 0
    assert List.last(events).attributes.seq == List.last(seqs) + 1
  end

  test "export/3 produces parseable OCEL 2.0 JSON with the four canonical keys", %{store: store} do
    {_tape, _final} = run_to_completion(store, "sroc-2")

    assert {:ok, json} = LedgerOCEL.export(store, "sroc-2")
    assert is_binary(json)

    assert {:ok, doc} = Jason.decode(json)

    assert MapSet.new(Map.keys(doc)) ==
             MapSet.new(["objectTypes", "eventTypes", "objects", "events"])

    assert %{"events" => ocel_events, "objects" => ocel_objects} = doc
    assert is_list(ocel_events) and ocel_events != []
    assert is_list(ocel_objects) and ocel_objects != []

    event_types = Enum.map(doc["eventTypes"], & &1["name"])
    assert "run_started" in event_types
    assert "task_succeeded" in event_types
    assert "run_ended" in event_types

    object_types = Enum.map(doc["objectTypes"], & &1["name"])
    assert "WorkflowRun" in object_types
    assert "Step" in object_types
    assert "Realization" in object_types

    assert Enum.any?(ocel_events, &(&1["type"] == "run_ended"))

    # anti-vacuity: the JSON event count equals the ledger event count
    assert {:ok, ledger_events} = LedgerOCEL.events(store, "sroc-2")
    assert length(ocel_events) == length(ledger_events)
  end

  test "digest/3 is stable across two calls on the same store", %{store: store} do
    {_tape, _final} = run_to_completion(store, "sroc-3")

    assert {:ok, d1} = LedgerOCEL.digest(store, "sroc-3")
    assert {:ok, d2} = LedgerOCEL.digest(store, "sroc-3")
    assert d1 == d2
    assert d1 =~ ~r/^[0-9a-f]{64}$/
  end

  test "digest changes when a standing checkpoint's output leaves the standing set", %{
    store: store
  } do
    providers = [Steps.Local, DurableGate]

    assert {:ok, s1} =
             Runtime.run(gated(), %{frontier: @frontier},
               providers: providers,
               store: store,
               run_id: "sroc-4"
             )

    assert s1.observation.state == :halted

    assert {:ok, d1} = LedgerOCEL.digest(store, "sroc-4")

    # lawful mutation: undo one standing checkpoint's output (the run is parked, so the
    # undo path is open) — the standing set shrinks and the digest must track it
    [standing_cp | _] = Ets.standing(store, "sroc-4")
    assert {:ok, _} = Ets.claim_undo(store, "sroc-4", standing_cp.step_key, Clock.now())

    assert {:ok, d2} = LedgerOCEL.digest(store, "sroc-4")
    refute d1 == d2
  end

  test "unknown run is a typed refusal", %{store: store} do
    assert {:error, %{reason: :no_such_run}} = LedgerOCEL.events(store, "sroc-ghost")
    assert {:error, %{reason: :no_such_run}} = LedgerOCEL.export(store, "sroc-ghost")
    assert {:error, %{reason: :no_such_run}} = LedgerOCEL.digest(store, "sroc-ghost")
  end
end

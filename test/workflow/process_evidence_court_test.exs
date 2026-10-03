defmodule AshPPlan.Workflow.ProcessEvidenceCourtTest do
  @moduledoc """
  Process-evidence court over a real run of the UltraCode workflow (real local
  provider, real Runtime). Events come from `AshPPlan.ProcessEvidence.events_from_receipt/3`
  and are routed through the ex4pm adapter, so every falsifier is checked on the
  ex4pm/OCEL2 form. No mocks.

  Falsifiers: duplicated consequential event, wrong object binding, and a
  self-report with no post-state event (no standing).
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Examples.UltraCode.Steps
  alias AshPPlan.ExecutionReceipt
  alias AshPPlan.ProcessEvidence
  alias AshPPlan.ProcessEvidence.Ex4pm, as: Adapter
  alias AshPPlan.Workflow.{Runtime, Subject}

  @workflow AshPPlan.Examples.Workflows.FileRelease

  defp receipt(state, started_at, mono) do
    ExecutionReceipt.observe(
      "urn:workflow:" <> state.subject.id,
      state.run_id,
      state.outcome,
      started_at,
      mono
    )
  end

  defp ex_events(evs) do
    assert {:ok, mapped} = Adapter.to_events(evs)
    mapped
  end

  defp acts(mapped), do: Enum.map(mapped, &{&1.attributes.task, &1.activity})

  defp expected(state, activities),
    do: for(t <- state.model.tasks, a <- activities, do: {to_string(t.id), a})

  defp diff(expected, observed) do
    e = Enum.frequencies(expected)
    o = Enum.frequencies(observed)

    Enum.reduce(Enum.uniq(Map.keys(e) ++ Map.keys(o)), {[], []}, fn k, {miss, extra} ->
      d = Map.get(o, k, 0) - Map.get(e, k, 0)

      cond do
        d < 0 -> {[k | miss], extra}
        d > 0 -> {miss, [k | extra]}
        true -> {miss, extra}
      end
    end)
  end

  @done ["task_attempted", "task_succeeded"]

  defp conformant?(state, mapped), do: diff(expected(state, @done), acts(mapped)) == {[], []}

  # Binding on the ex4pm form: subject attribute and the WorkflowRun/Capability relationships.
  defp bound?(state, mapped) do
    run = "run:" <> ExecutionReceipt.run_identifier(state.run_id)
    caps = Map.new(state.model.tasks, &{to_string(&1.id), "cap:" <> to_string(&1.capability)})

    Enum.all?(mapped, fn e ->
      ids = Enum.map(e.relationships, & &1.object_id)

      e.attributes.subject_id == state.subject.id and run in ids and
        Map.get(caps, e.attributes.task) in ids
    end)
  end

  defp standing?(mapped, task),
    do: Enum.any?(mapped, &(&1.attributes.task == task and &1.activity == "task_succeeded"))

  setup_all do
    started = DateTime.utc_now()
    mono = System.monotonic_time(:microsecond)

    {:ok, state} =
      Runtime.run(Steps.workflow(), %{frontier: [%{id: :a, status: :open, deps: []}]},
        providers: [Steps.Local]
      )

    r = receipt(state, started, mono)

    evs =
      ProcessEvidence.events_from_receipt(r, state.subject, tasks: state.model.tasks)

    {:ok, state: state, receipt: r, raw: evs, evs: ex_events(evs)}
  end

  test "real run yields subject-bound process evidence on the ex4pm form", ctx do
    %{state: s, receipt: r, raw: raw, evs: evs} = ctx
    assert s.observation.state == :succeeded
    assert r.status == :succeeded
    assert s.subject.id == Subject.bind(s.model).id
    assert Subject.bind(@workflow.model()).id =~ "sha256:"
    assert length(evs) == 2 * length(s.model.tasks)
    assert Enum.all?(evs, &match?(%{__struct__: Elixir.Ex4pm.Event}, &1))
    assert conformant?(s, evs)
    assert bound?(s, evs)
    assert Enum.all?(s.model.tasks, &standing?(evs, to_string(&1.id)))

    assert {:ok, json} = Adapter.export(raw, :ocel2_json)
    assert is_binary(json) and json =~ "task_succeeded"
  end

  test "ex4pm event log carries every event and object", %{raw: raw} do
    assert {:ok, log} = Adapter.to_event_log(raw)
    assert length(log.events) == length(raw)
    assert map_size(log.objects) > 0
  end

  test "falsifier: duplicated consequential event is detected", %{state: s, evs: evs} do
    dup = evs ++ [Enum.find(evs, &(&1.activity == "task_succeeded"))]
    refute conformant?(s, dup)
    {[], extra} = diff(expected(s, @done), acts(dup))
    assert [{_, "task_succeeded"}] = extra
  end

  test "falsifier: wrong object binding is detected", %{state: s, raw: raw} do
    [first | rest] = raw
    wrong_run = %{first | objects: [{"WorkflowRun", "run:other", "run"} | tl(first.objects)]}
    refute bound?(s, ex_events([wrong_run | rest]))

    wrong_subject = %{first | subject_id: "sha256:other"}
    assert {:ok, [m | _]} = Adapter.to_events([wrong_subject | rest])
    refute bound?(s, [m])
  end

  test "falsifier: self-report without post-state event has no standing", %{state: s, evs: evs} do
    task = to_string(hd(s.model.tasks).id)

    claimed =
      Enum.reject(evs, &(&1.attributes.task == task and &1.activity == "task_succeeded"))

    refute standing?(claimed, task)
    refute conformant?(s, claimed)
    {missing, []} = diff(expected(s, @done), acts(claimed))
    assert {task, "task_succeeded"} in missing
  end

  test "falsifier: a failed receipt yields no succeeded events", %{state: s, receipt: r} do
    failed = %{r | status: :failed}
    raw = ProcessEvidence.events_from_receipt(failed, s.subject, tasks: s.model.tasks)
    mapped = ex_events(raw)
    refute Enum.any?(mapped, &(&1.activity == "task_succeeded"))
    refute conformant?(s, mapped)
  end
end

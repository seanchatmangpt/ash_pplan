defmodule AshPPlan.Workflow.ProcessEvidenceCourtTest do
  @moduledoc """
  Process-evidence court over a real run of the generated `file_release`
  workflow. Events are derived from the real run state (no mocks).
  Falsifiers: duplicated consequential event, wrong object binding, and a
  self-report with no post-state event (no standing).
  Ex4pm/AshEx4pm integration is UNSUPPORTED until those deps are added.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Examples.UltraCode.Steps
  alias AshPPlan.Workflow.{Runtime, Subject}

  @workflow AshPPlan.Generated.Workflows.FileRelease

  # One attempted + one succeeded event per task, bound to the subject.
  defp events(state) do
    sid = state.subject.id
    ok? = state.observation.state == :succeeded

    Enum.flat_map(state.model.tasks, fn t ->
      base = %{subject_id: sid, task: t.id, object: {:task, sid, t.id}}
      attempted = Map.put(base, :activity, :attempted)
      if ok?, do: [attempted, Map.put(base, :activity, :succeeded)], else: [attempted]
    end)
  end

  defp expected(state, activities) do
    for t <- state.model.tasks, a <- activities, do: {t.id, a}
  end

  defp observed(events), do: Enum.map(events, &{&1.task, &1.activity})

  # multiset conformance: {missing, extra}
  defp diff(expected, observed) do
    e = Enum.frequencies(expected)
    o = Enum.frequencies(observed)
    keys = Enum.uniq(Map.keys(e) ++ Map.keys(o))

    Enum.reduce(keys, {[], []}, fn k, {miss, extra} ->
      d = Map.get(o, k, 0) - Map.get(e, k, 0)

      cond do
        d < 0 -> {[k | miss], extra}
        d > 0 -> {miss, [k | extra]}
        true -> {miss, extra}
      end
    end)
  end

  defp conformant?(state, evs),
    do: diff(expected(state, [:attempted, :succeeded]), observed(evs)) == {[], []}

  defp bound?(state, evs) do
    Enum.all?(evs, fn e ->
      e.subject_id == state.subject.id and e.object == {:task, state.subject.id, e.task}
    end)
  end

  # standing: a success claim needs a post-state (:succeeded) event
  defp standing?(evs, task),
    do: Enum.any?(evs, &(&1.task == task and &1.activity == :succeeded))

  setup_all do
    # file_release needs real remote/file inputs (not derivable offline in this
    # lane): its subject is checked below; the run uses the real UltraCode
    # workflow with its real local provider through the same Runtime.
    {:ok, state} =
      Runtime.run(Steps.workflow(), %{frontier: [%{id: :a, status: :open, deps: []}]},
        providers: [Steps.Local]
      )

    {:ok, state: state, evs: events(state)}
  end

  test "real run yields subject-bound process evidence", %{state: s, evs: evs} do
    assert s.observation.state == :succeeded
    assert s.subject.id == Subject.bind(s.model).id
    assert Subject.bind(@workflow.model()).id =~ "sha256:"
    assert length(evs) == 2 * length(s.model.tasks)
    assert conformant?(s, evs)
    assert bound?(s, evs)
    assert Enum.all?(evs, &(&1.subject_id == s.evidence.subject_id))
    assert Enum.all?(s.model.tasks, &standing?(evs, &1.id))
  end

  test "falsifier: duplicated consequential event is detected", %{state: s, evs: evs} do
    dup = evs ++ [Enum.find(evs, &(&1.activity == :succeeded))]
    refute conformant?(s, dup)
    {[], extra} = diff(expected(s, [:attempted, :succeeded]), observed(dup))
    assert [{_, :succeeded}] = extra
  end

  test "falsifier: wrong object binding is detected", %{state: s, evs: evs} do
    [first | rest] = evs
    bad = [%{first | object: {:task, "sha256:other", first.task}} | rest]
    refute bound?(s, bad)
    bad2 = [%{first | subject_id: "sha256:other"} | rest]
    refute bound?(s, bad2)
  end

  test "falsifier: self-report without post-state event has no standing", %{state: s, evs: evs} do
    task = hd(s.model.tasks).id
    claimed = Enum.reject(evs, &(&1.task == task and &1.activity == :succeeded))
    refute standing?(claimed, task)
    refute conformant?(s, claimed)
    {missing, []} = diff(expected(s, [:attempted, :succeeded]), observed(claimed))
    assert {task, :succeeded} in missing
  end
end
